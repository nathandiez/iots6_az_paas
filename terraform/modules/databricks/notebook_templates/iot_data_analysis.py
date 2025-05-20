# Title: IoT Data Analysis - Working with Real Device Data
# This notebook demonstrates how to access, process, and visualize real IoT data from the data lake

# COMMAND ----------
# Import necessary libraries
from pyspark.sql.types import *
from pyspark.sql.functions import *
import random
from datetime import datetime, timedelta

# COMMAND ----------
# Define storage details
storage_account = "niotv1devdatalake"
container = "rawdata"

# Storage key authentication with wasbs protocol
storage_key = "i7d/teKjy3OhazadQGxo5ClDtD1VSTzcNLVluyxctwPGkP+KrGsv+HVvCJaGPKVktl6gsj0HHTNC+ASttio7iQ=="

# Clear any previous configuration
spark.conf.unset(f"fs.azure.account.auth.type.{storage_account}.dfs.core.windows.net")
spark.conf.unset(
    f"fs.azure.account.oauth.provider.type.{storage_account}.dfs.core.windows.net"
)
spark.conf.unset(
    f"fs.azure.account.oauth2.client.id.{storage_account}.dfs.core.windows.net"
)
spark.conf.unset(
    f"fs.azure.account.oauth2.client.endpoint.{storage_account}.dfs.core.windows.net"
)

# Configure for wasbs protocol instead of abfss
spark.conf.set(
    f"fs.azure.account.key.{storage_account}.blob.core.windows.net", storage_key
)

print(f"Configured access using storage key authentication with wasbs protocol")

# COMMAND ----------
# Try accessing the data
try:
    # Use wasbs instead of abfss
    root_path = f"wasbs://{container}@{storage_account}.blob.core.windows.net/"
    print(f"Listing contents at: {root_path}")

    files = dbutils.fs.ls(root_path)
    print(f"Success! Found {len(files)} items at root level")
    display(files)

    # Continue exploring the data structure
    if len(files) == 1:
        first_item = files[0]
        print(f"Found item: {first_item.name} (is directory: {first_item.isDir})")

        # Check the contents of this item
        sub_files = dbutils.fs.ls(first_item.path)
        print(f"This item contains {len(sub_files)} items")
        display(sub_files)

        # Try to find the most recent data (assuming year/month/day/hour folder structure)
        if len(sub_files) > 0 and sub_files[0].isDir:
            # Find most recent year
            year_folders = sorted(
                [f for f in sub_files if f.name.isdigit() and len(f.name) == 4],
                key=lambda f: f.name,
                reverse=True,
            )
            if year_folders:
                latest_year = year_folders[0]
                print(f"Latest year: {latest_year.name}")

                # Find most recent month in that year
                months = dbutils.fs.ls(latest_year.path)
                latest_month = sorted(months, key=lambda f: f.name, reverse=True)[0]
                print(f"Latest month: {latest_month.name}")

                # Find most recent day in that month
                days = dbutils.fs.ls(latest_month.path)
                latest_day = sorted(days, key=lambda f: f.name, reverse=True)[0]
                print(f"Latest day: {latest_day.name}")

                # Find most recent hour in that day
                hours = dbutils.fs.ls(latest_day.path)
                latest_hour = sorted(hours, key=lambda f: f.name, reverse=True)[0]
                print(f"Latest hour: {latest_hour.name}")

                # Read the data from the most recent hour
                data_path = latest_hour.path
                print(f"Reading data from: {data_path}")
                df = spark.read.json(data_path)

                # Show schema and sample data
                print("Data schema:")
                df.printSchema()

                print("Sample data:")
                display(df.limit(10))

                # Convert timestamp if it exists
                if "timestamp" in df.columns:
                    df = df.withColumn("timestamp", to_timestamp(col("timestamp")))

                # Register as temp view for SQL
                df.createOrReplaceTempView("iot_data")

                # Show basic stats
                print(f"Total records: {df.count()}")
except Exception as e:
    print(f"Error: {str(e)}")

    # Try a direct mount as a last resort
    try:
        print("\nAttempting to mount the storage...")

        # Unmount if already mounted
        for mount in dbutils.fs.mounts():
            if mount.mountPoint == "/mnt/iotdata":
                dbutils.fs.unmount("/mnt/iotdata")
                print("Removed existing mount")

        # Create mount with storage key
        dbutils.fs.mount(
            source=f"wasbs://{container}@{storage_account}.blob.core.windows.net",
            mount_point="/mnt/iotdata",
            extra_configs={
                f"fs.azure.account.key.{storage_account}.blob.core.windows.net": storage_key
            },
        )

        print("Mount successful!")

        # List the mounted directory
        mount_files = dbutils.fs.ls("/mnt/iotdata")
        print(f"Found {len(mount_files)} items in mount")
        display(mount_files)
    except Exception as mount_error:
        print(f"Mount also failed: {str(mount_error)}")

# COMMAND ----------
# Example Analysis 1: Basic statistics for each device
if "df" in locals():
    print("Device Summary Statistics:")
    device_stats = df.groupBy("device_id").agg(
        count("*").alias("record_count"),
        min("timestamp").alias("first_record"),
        max("timestamp").alias("last_record"),
        avg("temperature").alias("avg_temperature"),
        min("temperature").alias("min_temperature"),
        max("temperature").alias("max_temperature"),
        avg("wifi_rssi").alias("avg_wifi_strength"),
        avg("fans_active_level").alias("avg_fan_level"),
    )

    display(device_stats)

# COMMAND ----------
# Example Analysis 2: Temperature trends over time
if "df" in locals():
    print("Temperature Trends Over Time:")

    # Add date and hour columns for time-based analysis
    df_with_time = df.withColumn("date", to_date("timestamp")).withColumn(
        "hour", hour("timestamp")
    )

    # Calculate hourly averages
    hourly_temps = (
        df_with_time.groupBy("device_id", "date", "hour")
        .agg(avg("temperature").alias("avg_temperature"))
        .orderBy("device_id", "date", "hour")
    )

    # Create a time series visual
    display(df.select("timestamp", "device_id", "temperature").orderBy("timestamp"))

# COMMAND ----------
# Example Analysis 3: Fan activity analysis
if "df" in locals():
    print("Fan Activity Analysis:")

    # Check fan level distribution
    fan_levels = (
        df.groupBy("device_id", "fans_active_level")
        .count()
        .orderBy("device_id", "fans_active_level")
    )

    print("Distribution of fan activity levels by device:")
    display(fan_levels)

    # Analyze relationship between temperature and fan levels
    print("\nTemperature vs. Fan Level Relationship:")
    temp_vs_fan = (
        df.groupBy("device_id", "fans_active_level")
        .agg(
            avg("temperature").alias("avg_temperature"),
            count("*").alias("record_count"),
        )
        .orderBy("device_id", "fans_active_level")
    )

    display(temp_vs_fan)

# COMMAND ----------
# Save processed insights (example)
if "df" in locals():
    # Prepare an hourly aggregated dataset
    hourly_insights = (
        df.withColumn("date", to_date("timestamp"))
        .withColumn("hour", hour("timestamp"))
        .groupBy("device_id", "date", "hour")
        .agg(
            count("*").alias("record_count"),
            avg("temperature").alias("avg_temperature"),
            min("temperature").alias("min_temperature"),
            max("temperature").alias("max_temperature"),
            avg("wifi_rssi").alias("avg_wifi_strength"),
            avg("fans_active_level").alias("avg_fan_level"),
            max("uptime_seconds").alias("max_uptime_seconds"),
        )
    )

    # Show the processed data that would be saved
    print("\nHourly aggregated insights that would be saved:")
    display(hourly_insights.limit(10))

    # Prepare the save path - using wasbs protocol for writing
    processed_path = f"wasbs://{container}@{storage_account}.blob.core.windows.net/processed/hourly_insights"

    print(f"\nTo save these insights, uncomment and run:")
    print(f'# hourly_insights.write.mode("overwrite").parquet("{processed_path}")')
