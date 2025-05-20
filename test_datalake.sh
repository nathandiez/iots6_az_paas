#!/bin/bash
# test_datalake.sh

echo "Fetching configuration from Terraform outputs..."

# Define the directory where your main Terraform configuration is located
TERRAFORM_CONFIG_DIR="./terraform"

# Fetch dynamic values from Terraform outputs
API_URL=$(terraform -chdir="$TERRAFORM_CONFIG_DIR" output -raw ingest_api_url)
STORAGE_ACCOUNT=$(terraform -chdir="$TERRAFORM_CONFIG_DIR" output -raw ingest_api_storage_account_name)
CONTAINER=$(terraform -chdir="$TERRAFORM_CONFIG_DIR" output -raw ingest_api_container_name)

# For the API Key, you can continue to use the hardcoded one if it matches
API_KEY="SuperSecretKey123ChangeMeLater"

# Validate that Terraform outputs were successfully retrieved
if [ -z "$API_URL" ] || [ "$API_URL" == "null" ]; then
    echo "Error: Failed to retrieve API_URL from Terraform output."
    echo "Please ensure 'ingest_api_url' is an output in '$TERRAFORM_CONFIG_DIR/main.tf' and 'terraform apply' was successful."
    exit 1
fi
if [ -z "$STORAGE_ACCOUNT" ] || [ "$STORAGE_ACCOUNT" == "null" ]; then
    echo "Error: Failed to retrieve STORAGE_ACCOUNT from Terraform output."
    echo "Please ensure 'ingest_api_storage_account_name' is an output in '$TERRAFORM_CONFIG_DIR/main.tf' and 'terraform apply' was successful."
    exit 1
fi
if [ -z "$CONTAINER" ] || [ "$CONTAINER" == "null" ]; then
    echo "Error: Failed to retrieve CONTAINER from Terraform output."
    echo "Please ensure 'ingest_api_container_name' is an output in '$TERRAFORM_CONFIG_DIR/main.tf' and 'terraform apply' was successful."
    exit 1
fi

echo "--- Test Configuration ---"
echo "API URL: $API_URL"
echo "Storage Account: $STORAGE_ACCOUNT"
echo "Container: $CONTAINER"
echo "--------------------------"

# Get the storage account key
echo "Fetching storage account key for $STORAGE_ACCOUNT..."
STORAGE_KEY=$(az storage account keys list --account-name "$STORAGE_ACCOUNT" --query "[0].value" -o tsv)

if [ -z "$STORAGE_KEY" ] || [ "$STORAGE_KEY" == "null" ]; then
    echo "Error: Failed to retrieve STORAGE_KEY for account '$STORAGE_ACCOUNT'."
    echo "Ensure your Azure CLI user has permissions to list keys for this storage account."
    exit 1
fi

# Generate test data
TEST_DATA=$(cat <<EOF
{
  "deviceId": "test-device-$(date +%s)",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "temperature": 23.5,
  "humidity": 45.2,
  "status": "active"
}
EOF
)

echo "Sending test data to API..."
echo "$TEST_DATA"
echo ""

# Post data to API
RESPONSE=$(curl -s -X POST "$API_URL" \
  -H "X-API-Key: $API_KEY" \
  -H 'Content-Type: application/json' \
  -d "$TEST_DATA" \
  -w "\n%{http_code}")

# Extract HTTP status code
HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)

echo "POST HTTP Status: $HTTP_STATUS"
echo ""

if [ "$HTTP_STATUS" != "202" ]; then
    echo "Failed to post data. API Response (excluding HTTP status):"
    echo "$RESPONSE" | head -n -1 # Print response body without the status code line
    exit 1
fi

# Wait for data to be written (adjust if needed)
echo "Waiting for data to be written to data lake..."
sleep 5 # Increased sleep slightly just in case of small delays

# Get current date/time for path
YEAR=$(date -u +"%Y")
MONTH=$(date -u +"%m")
DAY=$(date -u +"%d")
HOUR=$(date -u +"%H")

# Current hour directory
CURRENT_HOUR_PATH="$YEAR/$MONTH/$DAY/$HOUR/"

# Check current hour first
echo "Checking files in current hour: $CURRENT_HOUR_PATH"
CURRENT_HOUR_FILES=$(az storage fs file list \
  --file-system "$CONTAINER" \
  --path "$CURRENT_HOUR_PATH" \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --query "[].name" -o tsv 2>/dev/null)

# Only check previous hour if no files in current hour
if [ -z "$CURRENT_HOUR_FILES" ]; then
    # Try previous hour
    PREV_HOUR=$((10#$HOUR - 1))
    if [ $PREV_HOUR -lt 10 ]; then
        PREV_HOUR="0$PREV_HOUR"
    fi
    
    PREV_HOUR_PATH="$YEAR/$MONTH/$DAY/$PREV_HOUR/"
    
    echo "No files in current hour. Checking previous hour: $PREV_HOUR_PATH"
    PREV_HOUR_FILES=$(az storage fs file list \
      --file-system "$CONTAINER" \
      --path "$PREV_HOUR_PATH" \
      --account-name "$STORAGE_ACCOUNT" \
      --account-key "$STORAGE_KEY" \
      --query "[].name" -o tsv 2>/dev/null)
    
    FILES_IN_DATALAKE="$PREV_HOUR_FILES"
    FILE_PATH_PREFIX="$PREV_HOUR_PATH"
else
    FILES_IN_DATALAKE="$CURRENT_HOUR_FILES"
    FILE_PATH_PREFIX="$CURRENT_HOUR_PATH"
fi

if [ -z "$FILES_IN_DATALAKE" ]; then
    echo "No files found in either the current or previous hour directories."
    exit 1
fi

# Count the number of files
FILE_COUNT=$(echo "$FILES_IN_DATALAKE" | wc -l)
echo "Found $FILE_COUNT files in $FILE_PATH_PREFIX"

# Only process the most recent files (limit to 20)
# MAX_FILES_TO_PROCESS=20
# if [ $FILE_COUNT -gt $MAX_FILES_TO_PROCESS ]; then
#     echo "Limiting analysis to the $MAX_FILES_TO_PROCESS most recent files (by filename)..."
#     FILES_IN_DATALAKE=$(echo "$FILES_IN_DATALAKE" | sort | tail -n $MAX_FILES_TO_PROCESS)
# fi

# Create a temporary directory for downloads
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Store file info
declare -a FILE_INFO

echo "Analyzing files to find the most recent ones..."
for file in $FILES_IN_DATALAKE; do
    TEMP_FILE="$TEMP_DIR/$(basename "$file")"
    
    # Download the file
    az storage fs file download \
      --file-system "$CONTAINER" \
      --path "$file" \
      --destination "$TEMP_FILE" \
      --account-name "$STORAGE_ACCOUNT" \
      --account-key "$STORAGE_KEY" \
      --overwrite \
      -o none > /dev/null 2>&1
    
    # Extract timestamp from the file - adjust the grep pattern if your JSON format differs
    TIMESTAMP=$(grep -o '"timestamp":[[:space:]]*"[^"]*"' "$TEMP_FILE" 2>/dev/null | cut -d'"' -f4)
    DEVICE_ID=$(grep -o '"device[iI]d":[[:space:]]*"[^"]*"' "$TEMP_FILE" 2>/dev/null | cut -d'"' -f4)
    
    if [ -z "$TIMESTAMP" ]; then
        # Try alternate timestamp format
        TIMESTAMP=$(grep -o '"timestamp": *"[^"]*"' "$TEMP_FILE" 2>/dev/null | cut -d'"' -f4)
    fi
    
    if [ -z "$DEVICE_ID" ]; then
        # Try alternate device_id format
        DEVICE_ID=$(grep -o '"device_id":"[^"]*"' "$TEMP_FILE" 2>/dev/null | cut -d'"' -f4)
    fi
    
    # Add to array
    FILE_INFO+=("$TIMESTAMP|$DEVICE_ID|$file")
done

# Sort files by timestamp (newest first)
IFS=$'\n' SORTED_FILES=($(for info in "${FILE_INFO[@]}"; do echo "$info"; done | sort -r))
unset IFS

# Show the two most recent files
NUM_FILES=2
COUNTER=0

# If we have less than requested files, adjust
if [ ${#SORTED_FILES[@]} -lt $NUM_FILES ]; then
    NUM_FILES=${#SORTED_FILES[@]}
fi

for ((i=0; i<$NUM_FILES; i++)); do
    # Parse file info
    IFS='|' read -r TIMESTAMP DEVICE_ID FILE <<< "${SORTED_FILES[$i]}"
    
    echo ""
    echo "============================================="
    echo "Record #$((i+1)): $(basename "$FILE")"
    echo "Timestamp: $TIMESTAMP"
    echo "Device ID: $DEVICE_ID"
    echo "============================================="
    
    # Download the file to a readable name
    TEMP_OUTPUT_FILE="$TEMP_DIR/record_$((i+1)).json"
    az storage fs file download \
      --file-system "$CONTAINER" \
      --path "$FILE" \
      --destination "$TEMP_OUTPUT_FILE" \
      --account-name "$STORAGE_ACCOUNT" \
      --account-key "$STORAGE_KEY" \
      --overwrite \
      -o none > /dev/null 2>&1

    # Show the file contents
    echo "File contents:"
    cat "$TEMP_OUTPUT_FILE" | jq . 2>/dev/null || cat "$TEMP_OUTPUT_FILE"
    echo ""
done

echo "Test completed successfully"