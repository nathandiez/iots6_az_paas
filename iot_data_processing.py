# Databricks notebook source
# MAGIC %md
# MAGIC # IoT Data Processing
# MAGIC 
# MAGIC This notebook demonstrates how to process IoT data stored in Azure Data Lake Storage.

# COMMAND ----------

# Configuration
storage_account_name = "iotlearn2024ned"
container_name = "rawdata"

# COMMAND ----------

# Configure access to Azure Data Lake Storage
spark.conf.set(f"fs.azure.account.auth.type.{storage_account_name}.dfs.core.windows.net", "OAuth")
spark.conf.set(f"fs.azure.account.oauth.provider.type.{storage_account_name}.dfs.core.windows.net", "org.apache.hadoop.fs.azurebfs.oauth2.ClientCredsTokenProvider")
spark.conf.set(f"fs.azure.account.oauth2.client.id.{storage_account_name}.dfs.core.windows.net", dbutils.secrets.get(scope="azure-key-vault", key="databricks-app-client-id"))
spark.conf.set(f"fs.azure.account.oauth2.client.secret.{storage_account_name}.dfs.core.windows.net", dbutils.secrets.get(scope="azure-key-vault", key="databricks-app-client-secret"))
spark.conf.set(f"fs.azure.account.oauth2.client.endpoint.{storage_account_name}.dfs.core.windows.net", "https://login.microsoftonline.com/your-tenant-id/oauth2/token")

# COMMAND ----------

# Get today's date
from datetime import datetime
now = datetime.utcnow()
year, month, day, hour = now.strftime("%Y"), now.strftime("%m"), now.strftime("%d"), now.strftime("%H")

# COMMAND ----------

# Read data from ADLS
try:
    base_path = f"abfss://{container_name}@{storage_account_name}.dfs.core.windows.net/{year}/{month}/{day}/{hour}/"
    
    # Try to list files
    files = dbutils.fs.ls(base_path)
    
    if not files:
        print("No files found in the current hour directory.")
    else:
        # Read all JSON files
        df = spark.read.json([file.path for file in files if file.path.endswith(".json")])
        
        # Display the data
        display(df)
        
        # Create a temporary view for SQL queries
        df.createOrReplaceTempView("iot_raw_data")
        
        # Count records
        count = df.count()
        print(f"Found {count} records")
except Exception as e:
    print(f"Error accessing data: {str(e)}")

# COMMAND ----------

# MAGIC %sql
# MAGIC -- Basic analysis of the data
# MAGIC SELECT
# MAGIC   deviceId,
# MAGIC   AVG(temperature) as avg_temperature,
# MAGIC   AVG(humidity) as avg_humidity,
# MAGIC   COUNT(*) as record_count
# MAGIC FROM iot_raw_data
# MAGIC GROUP BY deviceId

# COMMAND ----------

# Save the data to a Delta table
try:
    if 'df' in locals():
        # Add processing timestamp
        from pyspark.sql.functions import current_timestamp
        df_with_ts = df.withColumn("processed_timestamp", current_timestamp())
        
        # Write to Delta table
        df_with_ts.write.format("delta").mode("append").saveAsTable("iot_data")
        
        print("Data saved to Delta table 'iot_data'")
    else:
        print("No data to save")
except Exception as e:
    print(f"Error saving to Delta table: {str(e)}")