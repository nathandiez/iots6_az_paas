#!/bin/bash
# test_datalake.sh

# Configuration
API_URL="https://iot-azure-api-app-ned.azurewebsites.net/api/ingest"
STORAGE_ACCOUNT="iotlearn2024ned"
CONTAINER="rawdata"

# Generate test data
TEST_DATA=$(cat <<EOF
{
  "deviceId": "test-device-001",
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
RESPONSE=$(curl -s -X POST $API_URL \
  -H 'X-API-Key: SuperSecretKey123!ChangeMeLater' \
  -H 'Content-Type: application/json' \
  -d "$TEST_DATA" \
  -w "\n%{http_code}")

# Extract HTTP status code
HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)

echo "HTTP Status: $HTTP_STATUS"
echo ""

if [ "$HTTP_STATUS" != "202" ]; then
    echo "Failed to post data. Response: $RESPONSE"
    exit 1
fi

# Wait for data to be written
echo "Waiting for data to be written..."
sleep 2

# Get current date/time for path
YEAR=$(date -u +"%Y")
MONTH=$(date -u +"%m")
DAY=$(date -u +"%d")
HOUR=$(date -u +"%H")

# List last 5 files
echo "Listing last 5 files..."
az storage fs file list \
  --file-system $CONTAINER \
  --path "$YEAR/$MONTH/$DAY/$HOUR/" \
  --account-name $STORAGE_ACCOUNT \
  --auth-mode login \
  --query "[-5:].name" -o json

# Get the last file and clean it
LAST_FILE=$(az storage fs file list \
  --file-system $CONTAINER \
  --path "$YEAR/$MONTH/$DAY/$HOUR/" \
  --account-name $STORAGE_ACCOUNT \
  --auth-mode login \
  --query "[-1].name" -o tsv | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

echo ""
echo "Last file: '$LAST_FILE'"
echo ""

# Use LAST_FILE directly
CLEAN_PATH="$LAST_FILE"

echo "Downloading file..."
echo "CLEAN_PATH: '$CLEAN_PATH'"

# Download the file
az storage fs file download \
  --file-system "$CONTAINER" \
  --path "$CLEAN_PATH" \
  --destination "./last_record.json" \
  --account-name "$STORAGE_ACCOUNT" \
  --auth-mode login \
  -o none


echo ""
echo "Contents of last record:"
cat last_record.json
