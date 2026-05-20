CREATE TABLE IF NOT EXISTS `transactional-496815.event_pipeline.audit_log` (
  batch_id STRING,
  source_file STRING,
  bucket STRING,
  partner_id STRING,
  entity STRING,
  status STRING,
  is_retryable BOOL,
  error_message STRING,
  started_at TIMESTAMP,
  finished_at TIMESTAMP,
  created_at TIMESTAMP
);

CREATE TABLE IF NOT EXISTS `transactional-496815.event_pipeline.staging_transactions` (
  transaction_id STRING,
  branch_id STRING,
  product_id STRING,
  quantity INT64,
  price NUMERIC,
  transaction_date DATE,
  currency STRING,
  source_file STRING,
  partner_id STRING,
  entity STRING,
  batch_id STRING,
  ingest_timestamp TIMESTAMP
);

CREATE TABLE IF NOT EXISTS `transactional-496815.event_pipeline.rejected_transactions` (
  transaction_id STRING,
  branch_id STRING,
  product_id STRING,
  quantity INT64,
  price NUMERIC,
  transaction_date DATE,
  currency STRING,
  source_file STRING,
  partner_id STRING,
  entity STRING,
  batch_id STRING,
  reject_reason STRING,
  rejected_at TIMESTAMP
);

CREATE TABLE IF NOT EXISTS `transactional-496815.event_pipeline.curated_transactions` (
  transaction_id STRING,
  branch_id STRING,
  product_id STRING,
  quantity INT64,
  price NUMERIC,
  transaction_date DATE,
  currency STRING,
  partner_id STRING,
  entity STRING,
  source_file STRING,
  batch_id STRING,
  created_at TIMESTAMP,
  updated_at TIMESTAMP
);

CREATE TABLE IF NOT EXISTS `transactional-496815.event_pipeline.raw_transactions` (
  transaction_id STRING,
  branch_id STRING,
  product_id STRING,
  quantity INT64,
  price NUMERIC,
  transaction_date DATE,
  currency STRING
);