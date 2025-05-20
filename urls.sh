#!/bin/bash
# urls.sh - Simple script to display project URLs

# Change to terraform directory
cd terraform

# Get URLs
CONFIG_URL=$(terraform output -json config_service_urls | grep -o 'http://[^"]*' | head -1)
INGEST_API_URL=$(terraform output -raw ingest_api_url)
DATABRICKS_URL=$(terraform output -raw databricks_workspace_url)

# Display URLs
echo "Configuration Service: $CONFIG_URL"
echo "Ingest API Endpoint: $INGEST_API_URL"
echo "Databricks Workspace: https://$DATABRICKS_URL"

# Return to original directory
cd ..