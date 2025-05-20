#!/bin/bash
# Script to update a config file in Azure Blob Storage

# Check if the file path is provided
if [ $# -lt 1 ]; then
  echo "Usage: $0 <config-file-path>"
  exit 1
fi

CONFIG_FILE=$1
FILENAME=$(basename "$CONFIG_FILE")
STORAGE_ACCOUNT=$(terraform -chdir=../terraform output -raw config_service_storage_account_name)
CONTAINER_NAME=$(terraform -chdir=../terraform output -raw config_service_container_name)

# Get the storage account key
STORAGE_KEY=$(az storage account keys list --account-name $STORAGE_ACCOUNT --query "[0].value" -o tsv)

# Upload the file
echo "Uploading $FILENAME to $STORAGE_ACCOUNT/$CONTAINER_NAME..."
az storage blob upload \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$CONTAINER_NAME" \
  --name "$FILENAME" \
  --file "$CONFIG_FILE" \
  --account-key "$STORAGE_KEY" \
  --overwrite

if [ $? -eq 0 ]; then
  echo "Config file updated successfully!"
  echo "URL: http://$STORAGE_ACCOUNT.blob.core.windows.net/$CONTAINER_NAME/$FILENAME"
else
  echo "Failed to update config file"
fi