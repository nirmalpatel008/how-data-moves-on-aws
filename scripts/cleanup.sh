#!/usr/bin/env bash
# ------------------------------------------------------------------
# Deletes everything the demo created, so nothing keeps costing you.
# Run this in AWS CloudShell when you're done.
# ------------------------------------------------------------------
set -uo pipefail

REGION="${AWS_REGION:-ap-south-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="how-data-moves-${ACCOUNT_ID}-${REGION}"
ROLE_NAME="GlueDemoRole"
DATABASE="canteen_db"
CRAWLER="canteen-raw-crawler"
JOB="clean-canteen-orders"

echo "Deleting Glue job and crawler..."
aws glue delete-job --job-name "$JOB" --region "$REGION" >/dev/null 2>&1
aws glue delete-crawler --name "$CRAWLER" --region "$REGION" >/dev/null 2>&1

echo "Deleting Glue database (and its tables)..."
aws glue delete-database --name "$DATABASE" --region "$REGION" >/dev/null 2>&1

echo "Deleting IAM role..."
aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name DemoBucketAccess >/dev/null 2>&1
aws iam detach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole >/dev/null 2>&1
aws iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1

echo "Emptying and deleting bucket $BUCKET..."
aws s3 rb "s3://$BUCKET" --force >/dev/null 2>&1

echo "Done. Also check the Glue console for any leftover jobs or crawlers with other names."
