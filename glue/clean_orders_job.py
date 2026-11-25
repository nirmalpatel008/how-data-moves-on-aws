"""
AWS Glue ETL job: clean the raw canteen orders and save them as Parquet.

Reads : the raw CSV table that the Glue crawler created  (canteen_db.orders)
Writes: clean Parquet files to S3, split into folders by order_date,
        and creates/updates the table canteen_db.orders_clean in the Data Catalog

Job parameters (set these in the Glue console under "Job parameters"):
  --DATABASE       canteen_db
  --SOURCE_TABLE   orders
  --TARGET_PATH    s3://<your-bucket>/processed/orders_clean/
  --TARGET_TABLE   orders_clean
"""

import sys

from awsglue.context import GlueContext
from awsglue.dynamicframe import DynamicFrame
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import DataFrame
from pyspark.sql import functions as F


def clean_orders(df: DataFrame) -> DataFrame:
    """All the cleaning rules live here, so they're easy to read (and test)."""
    return (
        df
        # 1. Fix messy item names: "  vada pav " / "VADA PAV" -> "Vada Pav"
        .withColumn("item", F.initcap(F.trim(F.col("item"))))
        # 2. Make sure numbers are numbers and time is a real timestamp
        .withColumn("quantity", F.col("quantity").cast("int"))
        .withColumn("unit_price", F.col("unit_price").cast("double"))
        .withColumn("order_time", F.to_timestamp("order_time", "yyyy-MM-dd HH:mm:ss"))
        # 3. Blank payment mode -> "Unknown"
        .withColumn(
            "payment_mode",
            F.when(F.trim(F.coalesce(F.col("payment_mode"), F.lit(""))) == "", "Unknown")
            .otherwise(F.trim(F.col("payment_mode"))),
        )
        # 4. Remove cancelled orders (quantity 0)
        .filter(F.col("quantity") > 0)
        # 5. Remove duplicate rows (same order scanned twice)
        .dropDuplicates(["order_id"])
        # 6. Add useful columns for analysis
        .withColumn("total_amount", F.col("quantity") * F.col("unit_price"))
        .withColumn("order_hour", F.hour("order_time"))
        .withColumn("order_date", F.date_format("order_time", "yyyy-MM-dd"))
    )


def main() -> None:
    args = getResolvedOptions(
        sys.argv, ["JOB_NAME", "DATABASE", "SOURCE_TABLE", "TARGET_PATH", "TARGET_TABLE"]
    )

    sc = SparkContext()
    glue_context = GlueContext(sc)
    job = Job(glue_context)
    job.init(args["JOB_NAME"], args)

    # Read the raw table that the crawler made
    raw = glue_context.create_dynamic_frame.from_catalog(
        database=args["DATABASE"], table_name=args["SOURCE_TABLE"]
    )
    print(f"Raw rows: {raw.count()}")

    clean_df = clean_orders(raw.toDF())
    print(f"Clean rows: {clean_df.count()}")

    clean = DynamicFrame.fromDF(clean_df, glue_context, "clean")

    # Empty the output folder first, so running the job twice doesn't double the data
    glue_context.purge_s3_path(args["TARGET_PATH"], {"retentionPeriod": 0})

    # Write Parquet to S3, one folder per day, and register the table in the catalog
    sink = glue_context.getSink(
        connection_type="s3",
        path=args["TARGET_PATH"],
        enableUpdateCatalog=True,
        updateBehavior="UPDATE_IN_DATABASE",
        partitionKeys=["order_date"],
    )
    sink.setFormat("glueparquet", compression="snappy")
    sink.setCatalogInfo(catalogDatabase=args["DATABASE"], catalogTableName=args["TARGET_TABLE"])
    sink.writeFrame(clean)

    job.commit()


if __name__ == "__main__":
    main()
