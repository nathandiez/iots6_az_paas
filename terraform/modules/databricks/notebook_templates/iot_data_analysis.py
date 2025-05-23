# Extra Simple IoT Data Viewer

# COMMAND ----------
# 1. Configure storage access
storage_account = "niotv1devdatalake"
container = "rawdata"
storage_key = "GFsUC5y5Q/TSeHc2Rf1JdXLvmzK74aHQQF+BmEuh6K4Qc4whM2ctnwA+SutJAHrGQZdCkPMcZ/qj+AStbayPQw=="

# Set up connection
spark.conf.set(
    f"fs.azure.account.key.{storage_account}.blob.core.windows.net", storage_key
)

print("Storage access configured")

# COMMAND ----------
# 2. List files to see what's actually there
data_path = f"wasbs://{container}@{storage_account}.blob.core.windows.net/2025/05/20/"
print(f"Exploring: {data_path}")

files = dbutils.fs.ls(data_path)
print(f"Found {len(files)} items in this path")
display(files)

# COMMAND ----------
# 3. Try to read individual files
# Get the first file if any exist
if len(files) > 0:
    first_file = files[0].path
    print(f"Trying to read: {first_file}")
    
    # Read just this one file
    df = spark.read.json(first_file)
    
    # Show basic info
    print(f"Successfully read file with {df.count()} records")
    print("Data schema:")
    df.printSchema()
    
    # Display sample data
    print("Sample data:")
    display(df.limit(5))
else:
    print("No files found in the specified path")