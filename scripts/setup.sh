#!/usr/bin/env bash
# ------------------------------------------------------------------
# One-time setup. Run this in AWS CloudShell (it already has the AWS CLI).
#
# It creates:
#   1. an S3 bucket with raw data, the Glue script and an Athena results folder
#   2. an IAM role that AWS Glue can use (GlueDemoRole)
#   3. a Glue database (canteen_db)
#
# Then you do the fun part (crawler, job, queries) in the console.
# ------------------------------------------------------------------
set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="how-data-moves-${ACCOUNT_ID}-${REGION}"
ROLE_NAME="GlueDemoRole"
DATABASE="canteen_db"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Region : $REGION"
echo "Bucket : $BUCKET"

# 1. S3 bucket + files
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "Bucket already exists, reusing it"
elif [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
fi

aws s3 cp "$REPO_DIR/data/raw/orders/" "s3://$BUCKET/raw/orders/" --recursive
aws s3 cp "$REPO_DIR/glue/clean_orders_job.py" "s3://$BUCKET/scripts/clean_orders_job.py"
echo "Uploaded raw data and Glue script"

# 2. IAM role for Glue
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{"Effect": "Allow", "Principal": {"Service": "glue.amazonaws.com"}, "Action": "sts:AssumeRole"}]
    }' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole
  echo "Created IAM role $ROLE_NAME"
fi

# Let the role read and write only our bucket
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name DemoBucketAccess \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"s3:GetObject\", \"s3:PutObject\", \"s3:DeleteObject\", \"s3:ListBucket\"],
      \"Resource\": [\"arn:aws:s3:::$BUCKET\", \"arn:aws:s3:::$BUCKET/*\"]
    }]
  }"

# 3. Glue database
aws glue create-database --region "$REGION" --database-input "{\"Name\": \"$DATABASE\"}" 2>/dev/null \
  && echo "Created Glue database $DATABASE" || echo "Glue database $DATABASE already exists"

cat <<EOF

All set! Copy these values, you'll need them in the console:

  Bucket            : $BUCKET
  Raw data path     : s3://$BUCKET/raw/orders/
  Glue script path  : s3://$BUCKET/scripts/clean_orders_job.py
  Clean data path   : s3://$BUCKET/processed/orders_clean/
  Athena results    : s3://$BUCKET/athena-results/
  IAM role          : $ROLE_NAME
  Glue database     : $DATABASE

Next: follow "Step 2" in the README.
EOF
