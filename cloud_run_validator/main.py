import re
import csv
from flask import Flask, request, jsonify
from google.cloud import storage

app = Flask(__name__)

EXPECTED_COLUMNS = [
    "transaction_id",
    "branch_id",
    "product_id",
    "quantity",
    "price",
    "transaction_date",
    "currency",
]

VALID_PARTNERS = {"PARTNER_A", "PARTNER_B"}
VALID_ENTITIES = {"sales"}

PATH_REGEX = re.compile(
    r"^incoming/(?P<partner_id>[A-Z0-9_]+)/(?P<entity>[a-zA-Z0-9_]+)/transactions_(?P<date>\d{8})\.csv$"
)

storage_client = storage.Client()


@app.route("/validate", methods=["POST"])
def validate():
    data = request.get_json(silent=True) or {}

    bucket_name = data.get("bucket")
    object_name = data.get("name")

    errors = []
    detected_columns = []
    partner_id = None
    entity = None

    if not bucket_name:
        errors.append("Missing bucket")

    if not object_name:
        errors.append("Missing object name")

    if errors:
        return jsonify({
            "valid": False,
            "retryable": False,
            "partner_id": partner_id,
            "entity": entity,
            "detected_columns": detected_columns,
            "errors": errors
        }), 400

    match = PATH_REGEX.match(object_name)

    if not match:
        errors.append("Invalid file path pattern")
        return jsonify({
            "valid": False,
            "retryable": False,
            "partner_id": partner_id,
            "entity": entity,
            "detected_columns": detected_columns,
            "errors": errors
        }), 200

    partner_id = match.group("partner_id")
    entity = match.group("entity")

    if partner_id not in VALID_PARTNERS:
        errors.append(f"Invalid partner_id: {partner_id}")

    if entity not in VALID_ENTITIES:
        errors.append(f"Invalid entity: {entity}")

    try:
        bucket = storage_client.bucket(bucket_name)
        blob = bucket.blob(object_name)

        header_text = blob.download_as_text(start=0, end=2048)
        first_line = header_text.splitlines()[0]
        detected_columns = next(csv.reader([first_line]))

    except Exception as e:
        return jsonify({
            "valid": False,
            "retryable": True,
            "partner_id": partner_id,
            "entity": entity,
            "detected_columns": detected_columns,
            "errors": [f"Failed to read CSV header: {str(e)}"]
        }), 200

    if detected_columns != EXPECTED_COLUMNS:
        errors.append("Schema mismatch")

    return jsonify({
        "valid": len(errors) == 0,
        "retryable": False,
        "partner_id": partner_id,
        "entity": entity,
        "detected_columns": detected_columns,
        "errors": errors
    }), 200


@app.route("/", methods=["GET"])
def health():
    return "OK", 200