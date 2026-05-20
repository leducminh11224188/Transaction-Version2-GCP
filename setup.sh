#!/usr/bin/env bash
set -euo pipefail

# Assignment 04 setup script.
# Run from the repository root in Google Cloud Shell:
#   chmod +x setup.sh
#   ./setup.sh

PROJECT_ID="${PROJECT_ID:-transactional-496815}"
REGION="${REGION:-asia-southeast1}"
DATASET="${DATASET:-event_pipeline}"
LANDING_BUCKET="${LANDING_BUCKET:-${PROJECT_ID}-landing}"
DLQ_TOPIC="${DLQ_TOPIC:-transaction-dlq}"
WORKFLOW_NAME="${WORKFLOW_NAME:-transaction-ingestion-workflow}"
VALIDATOR_SERVICE="${VALIDATOR_SERVICE:-transaction-validator}"
WORKFLOW_SA="${WORKFLOW_SA:-workflow-sa}"
VALIDATOR_SA="${VALIDATOR_SA:-validator-sa}"
EVENTARC_TRIGGER="${EVENTARC_TRIGGER:-gcs-finalized-trigger}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_SA_EMAIL="${WORKFLOW_SA}@${PROJECT_ID}.iam.gserviceaccount.com"
VALIDATOR_SA_EMAIL="${VALIDATOR_SA}@${PROJECT_ID}.iam.gserviceaccount.com"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

create_service_account() {
  local name="$1"
  local display_name="$2"

  if gcloud iam service-accounts describe "${name}@${PROJECT_ID}.iam.gserviceaccount.com" >/dev/null 2>&1; then
    echo "Service account exists: ${name}"
  else
    gcloud iam service-accounts create "${name}" \
      --display-name="${display_name}" \
      --quiet
  fi
}

grant_role() {
  local member="$1"
  local role="$2"

  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="${member}" \
    --role="${role}" \
    --quiet >/dev/null
}

grant_role_if_service_account_exists() {
  local email="$1"
  local role="$2"

  if gcloud iam service-accounts describe "${email}" >/dev/null 2>&1; then
    grant_role "serviceAccount:${email}" "${role}"
  else
    echo "Skipping IAM grant for missing service account: ${email}"
  fi
}

echo "Project: ${PROJECT_ID}"
echo "Region:  ${REGION}"

require_command gcloud
require_command gsutil
require_command bq
require_command sed

gcloud config set project "${PROJECT_ID}" >/dev/null

echo "Phase 1/2: Enable APIs"
gcloud services enable \
  storage.googleapis.com \
  eventarc.googleapis.com \
  workflows.googleapis.com \
  workflowexecutions.googleapis.com \
  run.googleapis.com \
  bigquery.googleapis.com \
  pubsub.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  logging.googleapis.com \
  --quiet

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")"
GCS_SERVICE_AGENT="service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com"
COMPUTE_DEFAULT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
CLOUDBUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

echo "Phase 2: Create GCS bucket"
if gsutil ls -b "gs://${LANDING_BUCKET}" >/dev/null 2>&1; then
  echo "Bucket exists: gs://${LANDING_BUCKET}"
else
  gsutil mb -p "${PROJECT_ID}" -l "${REGION}" "gs://${LANDING_BUCKET}"
fi

echo "Phase 2: Create Pub/Sub DLQ topic"
if gcloud pubsub topics describe "${DLQ_TOPIC}" >/dev/null 2>&1; then
  echo "Topic exists: ${DLQ_TOPIC}"
else
  gcloud pubsub topics create "${DLQ_TOPIC}" --quiet
fi

echo "Phase 2: Create service accounts"
create_service_account "${WORKFLOW_SA}" "Workflow Service Account"
create_service_account "${VALIDATOR_SA}" "Validator Service Account"

echo "Phase 2: Grant IAM roles"
grant_role "serviceAccount:${WORKFLOW_SA_EMAIL}" "roles/bigquery.jobUser"
grant_role "serviceAccount:${WORKFLOW_SA_EMAIL}" "roles/bigquery.dataEditor"
grant_role "serviceAccount:${WORKFLOW_SA_EMAIL}" "roles/pubsub.publisher"
grant_role "serviceAccount:${WORKFLOW_SA_EMAIL}" "roles/run.invoker"
grant_role "serviceAccount:${WORKFLOW_SA_EMAIL}" "roles/eventarc.eventReceiver"
grant_role "serviceAccount:${WORKFLOW_SA_EMAIL}" "roles/logging.logWriter"
grant_role "serviceAccount:${WORKFLOW_SA_EMAIL}" "roles/storage.objectViewer"

grant_role "serviceAccount:${VALIDATOR_SA_EMAIL}" "roles/storage.objectViewer"
grant_role "serviceAccount:${VALIDATOR_SA_EMAIL}" "roles/logging.logWriter"

# Required by Cloud Storage events delivered through Eventarc.
grant_role "serviceAccount:${GCS_SERVICE_AGENT}" "roles/pubsub.publisher"

# Helps gcloud run deploy --source in projects where Cloud Build reads uploaded source
# through the default compute/build identities.
grant_role_if_service_account_exists "${COMPUTE_DEFAULT_SA}" "roles/storage.objectViewer"
grant_role_if_service_account_exists "${CLOUDBUILD_SA}" "roles/storage.objectViewer"

echo "Phase 3: Create BigQuery dataset and tables"
if bq --project_id="${PROJECT_ID}" show --dataset "${PROJECT_ID}:${DATASET}" >/dev/null 2>&1; then
  echo "Dataset exists: ${PROJECT_ID}:${DATASET}"
else
  bq --project_id="${PROJECT_ID}" mk \
    --dataset \
    --location="${REGION}" \
    "${PROJECT_ID}:${DATASET}"
fi

TMP_DDL="$(mktemp)"
sed "s/transactional-496815/${PROJECT_ID}/g" "${ROOT_DIR}/ddl.sql" > "${TMP_DDL}"
bq --project_id="${PROJECT_ID}" query --use_legacy_sql=false < "${TMP_DDL}"
rm -f "${TMP_DDL}"

echo "Phase 6: Deploy Cloud Run validator"
gcloud run deploy "${VALIDATOR_SERVICE}" \
  --source="${ROOT_DIR}/cloud_run_validator" \
  --region="${REGION}" \
  --service-account="${VALIDATOR_SA_EMAIL}" \
  --no-allow-unauthenticated \
  --quiet

VALIDATOR_URL="$(gcloud run services describe "${VALIDATOR_SERVICE}" \
  --region="${REGION}" \
  --format="value(status.url)")"
echo "Validator URL: ${VALIDATOR_URL}"

echo "Phase 8: Deploy Workflow"
TMP_WORKFLOW="$(mktemp)"
sed \
  -e "s/transactional-496815/${PROJECT_ID}/g" \
  -e "s#validator_url: \".*\"#validator_url: \"${VALIDATOR_URL}\"#g" \
  "${ROOT_DIR}/workflow.yaml" > "${TMP_WORKFLOW}"

gcloud workflows deploy "${WORKFLOW_NAME}" \
  --source="${TMP_WORKFLOW}" \
  --location="${REGION}" \
  --service-account="${WORKFLOW_SA_EMAIL}" \
  --quiet
rm -f "${TMP_WORKFLOW}"

echo "Phase 9: Create Eventarc trigger"
if gcloud eventarc triggers describe "${EVENTARC_TRIGGER}" --location="${REGION}" >/dev/null 2>&1; then
  echo "Trigger exists, updating destination/service account: ${EVENTARC_TRIGGER}"
  gcloud eventarc triggers update "${EVENTARC_TRIGGER}" \
    --location="${REGION}" \
    --destination-workflow="${WORKFLOW_NAME}" \
    --destination-workflow-location="${REGION}" \
    --service-account="${WORKFLOW_SA_EMAIL}" \
    --quiet
else
  gcloud eventarc triggers create "${EVENTARC_TRIGGER}" \
    --location="${REGION}" \
    --destination-workflow="${WORKFLOW_NAME}" \
    --destination-workflow-location="${REGION}" \
    --event-filters="type=google.cloud.storage.object.v1.finalized" \
    --event-filters="bucket=${LANDING_BUCKET}" \
    --service-account="${WORKFLOW_SA_EMAIL}" \
    --quiet
fi

cat <<EOF

Setup complete.

Exports for manual testing:
  export PROJECT_ID=${PROJECT_ID}
  export REGION=${REGION}
  export DATASET=${DATASET}
  export LANDING_BUCKET=${LANDING_BUCKET}
  export DLQ_TOPIC=${DLQ_TOPIC}
  export WORKFLOW_NAME=${WORKFLOW_NAME}
  export VALIDATOR_SERVICE=${VALIDATOR_SERVICE}
  export WORKFLOW_SA=${WORKFLOW_SA}
  export VALIDATOR_SA=${VALIDATOR_SA}

Phase 10 test commands:
  gsutil cp test_files/valid.csv gs://${LANDING_BUCKET}/incoming/PARTNER_A/sales/transactions_20250510.csv
  gsutil cp test_files/valid.csv gs://${LANDING_BUCKET}/incom/PARTNER_A/sales/transactions_20250501.csv
  gsutil cp test_files/invalid_schema.csv gs://${LANDING_BUCKET}/incoming/PARTNER_A/sales/transactions_20250503.csv
  gsutil cp test_files/invalid_rows.csv gs://${LANDING_BUCKET}/incoming/PARTNER_A/sales/transactions_20250504.csv
  gsutil cp test_files/duplicate.csv gs://${LANDING_BUCKET}/incoming/PARTNER_A/sales/transactions_20250510.csv

BigQuery check:
  bq query --use_legacy_sql=false "SELECT status, source_file, error_message, created_at FROM \\\`${PROJECT_ID}.${DATASET}.audit_log\\\` ORDER BY created_at DESC LIMIT 20"

EOF
