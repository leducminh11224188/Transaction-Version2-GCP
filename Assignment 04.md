# Assignment: Event-Driven Data Platform with Eventarc, GCS, Workflows, BigQuery, Cloud Run, and Pub/Sub Dead-Letter

## Overview
In this assignment, you will design and implement a **production-like event-driven data pipeline** on **Google Cloud** using:

- **Google Cloud Storage (GCS)**
- **Eventarc**
- **Workflows**
- **BigQuery**
- **Cloud Run**
- **Pub/Sub**

The solution must process CSV files uploaded to GCS, validate them, orchestrate ingestion, handle data quality checks, load valid data into BigQuery, isolate invalid data, and publish retryable failures to a Pub/Sub dead-letter topic.

---

## Learning Objectives
By completing this assignment, you should be able to:

- Build an event-driven architecture on Google Cloud
- Use Eventarc to react to GCS object events
- Orchestrate multi-step processing using Workflows
- Implement custom validation logic in Cloud Run
- Load, validate, and merge data in BigQuery
- Design audit logging and idempotent ingestion
- Handle retryable failures using Pub/Sub dead-letter patterns

---

## Business Context
A company receives daily transaction files from multiple external partners. These files are uploaded to a GCS landing bucket. However, incoming files are not always trustworthy:

- Some files have invalid naming conventions
- Some have schema mismatches
- Some contain partially invalid records
- Some are uploaded multiple times
- Some fail due to temporary infrastructure issues

Your task is to implement a robust ingestion pipeline that:

1. Automatically reacts to new files
2. Rejects invalid files early
3. Prevents duplicate processing
4. Loads data into BigQuery staging
5. Separates valid and invalid records
6. Merges valid records into a curated table
7. Writes a complete audit trail
8. Sends retryable failures to a dead-letter topic for reprocessing

---

## Required Google Cloud Services
You must use the following services:

- **Google Cloud Storage**
- **Eventarc**
- **Workflows**
- **BigQuery**
- **Cloud Run**
- **Pub/Sub**

---

## Target Architecture

```text
                +----------------------+
                |   GCS Landing Bucket |
                +----------+-----------+
                           |
                           | object finalized
                           v
                      +-----------+
                      | Eventarc  |
                      +-----------+
                           |
                           v
                      +-----------+
                      | Workflows |
                      +-----------+
                      /    |    \
                     /     |     \
                    v      v      v
            +-----------+  |  +----------------+
            | Cloud Run |  |  | BigQuery       |
            | Validator |  |  | staging/audit  |
            +-----------+  |  | curated/reject |
                           |  +----------------+
                           |
                           v
                    +----------------+
                    | Pub/Sub DLQ    |
                    | dead-letter    |
                    +----------------+
```

## Accepted File Path Pattern
`incoming/{partner_id}/{entity}/transactions_YYYYMMDD.csv`

**Examples**
1. Valid examples:
     - `incoming/PARTNER_A/sales/transactions_20250501.csv`
     - `incoming/PARTNER_B/sales/transactions_20250502.csv`
2. Invalid examples:
     - `tmp/PARTNER_A/sales/transactions_20250501.csv`
     - `incoming/PARTNER_A/transactions_20250501.csv`
     - `incoming/PARTNER_A/sales/file.csv`
     - `incoming/PARTNER_A/sales/transactions_may01.csv`

## CSV Format
1. Expected Header
     - `transaction_id,branch_id,product_id,quantity,price,transaction_date,currency`

## Functional Requirements
### 1. Triggering
When a file is uploaded to the GCS landing bucket:
- Eventarc must capture the event
- Event type must be: `google.cloud.storage.object.v1.finalized`
- Eventarc must trigger a **Workflow**

### 2. Workflow Responsibilities
1. Initialize processing context
2. Extract event metadata
3. Validate basic path and naming format
4. Write an initial audit record
5. Call a Cloud Run validation service
6. Check duplicate processing status
7. Load valid files into BigQuery staging
8. Run data quality checks
9. Insert invalid records into a rejected table
10. Merge valid records into a curated table
11. Compute final processing outcome
12. Write a final audit record
13. Publish retryable failures to Pub/Sub DLQ when applicable

### 3. Cloud Run Validation Responsibilities
The Cloud Run service must expose an HTTP endpoint: `POST /validate`

It must perform the following checks:
- Parse the GCS object path
- Validate `partner_id`
- Validate `entity`
- Read the CSV header from `GCS`
- Compare the actual schema with the expected schema
- Return a structured JSON response including:
     - whether the file is valid
     - whether the failure is retryable
     - detected columns
     - parsed partner/entity
     - error list

### 4. BigQuery Processing Requirements
The solution must include the following BigQuery processing logic:
- Load file data into a staging table
- Add metadata such as:
     - source file
     - partner id
     - batch id
     - ingest timestamp
- Apply data quality rules
- Send invalid rows to a rejected table
- Merge valid rows into a curated table using `MERGE` **(SCD, CDM)**

### 5. Dead-Letter Handling
Retryable failures must be published to a Pub/Sub dead-letter topic.

**Examples of retryable failures:**
- Cloud Run validator timeout
- temporary Cloud Run 5xx response
- transient BigQuery job failure
- dependency unavailable

**Examples of non-retryable failures:**
- invalid path
- invalid partner
- schema mismatch
- missing required columns

## Business Rules
Your pipeline must enforce all of the following rules:
1. transaction_id must not be null
2. branch_id must not be null
3. quantity > 0
4. price > 0
5. transaction_date <= current_date
6. currency must be one of:
     - VND
     - USD
     - EUR
7. partner_id extracted from the path must be in a whitelist
8. file name must match required regex pattern
9. duplicate files must not be processed again if already completed successfully
10. retryable failures must be sent to Pub/Sub DLQ