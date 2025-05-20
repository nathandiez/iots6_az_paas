#!/usr/bin/env bash
# create_databricks_sp.sh - Creates a Service Principal for Databricks automation
# 
# This script:
# 1. Creates an Azure Service Principal with Contributor access to the Databricks workspace
# 2. Assigns Owner role to the SP on the Databricks workspace
# 3. Creates terraform.tfvars with proper credentials for the Databricks provider
#
# Usage: ./create_databricks_sp.sh <RESOURCE_GROUP> <WORKSPACE_NAME>
# Example: ./create_databricks_sp.sh niotv1-dev-rg niotv1-dev-databricks

set -euo pipefail

if [ $# -lt 2 ]; then
  cat <<EOF
Usage: $0 <RESOURCE_GROUP> <WORKSPACE_NAME> [SUBSCRIPTION_ID]

Example:
  $0 niotv1-dev-rg niotv1-dev-databricks

This script:
1. Creates an Azure Service Principal with Contributor access to the Databricks workspace
2. Assigns Owner role to the SP on the Databricks workspace 
3. Creates terraform.tfvars with proper credentials for the Databricks provider
EOF
  exit 1
fi

RG="$1"
WORKSPACE="$2"
SUBSCRIPTION_ID="${3:-$(az account show --query id -o tsv)}"

echo "▶ Using subscription: $SUBSCRIPTION_ID"
echo "▶ Resource Group:     $RG"
echo "▶ Workspace Name:     $WORKSPACE"
echo

echo "1️⃣  Creating Service Principal..."
# Use --sdk-auth for proper format
az ad sp create-for-rbac \
  --name "databricks-$WORKSPACE" \
  --role Contributor \
  --scopes "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Databricks/workspaces/${WORKSPACE}" \
  --sdk-auth > databricks-sp.json

# Extract the client ID for later use
CLIENT_ID=$(jq -r .clientId databricks-sp.json)
CLIENT_SECRET=$(jq -r .clientSecret databricks-sp.json)
TENANT_ID=$(jq -r .tenantId databricks-sp.json)
echo "   ✅  Created Service Principal (Client ID: $CLIENT_ID)"
echo "   ✅  Saved credentials to databricks-sp.json"
echo

echo "2️⃣  Fetching workspace ARM ID..."
WORKSPACE_ID=$(az databricks workspace show \
  --name "$WORKSPACE" \
  --resource-group "$RG" \
  --query id -o tsv)
echo "   Workspace ID: $WORKSPACE_ID"
echo

echo "3️⃣  Assigning Owner role to SP on that workspace..."
az role assignment create \
  --assignee "$CLIENT_ID" \
  --role Owner \
  --scope "$WORKSPACE_ID"
echo "   ✅  Service Principal is now Owner of the workspace"
echo

echo "4️⃣  Getting workspace URL..."
WS_URL=$(az databricks workspace show \
  --name "$WORKSPACE" \
  --resource-group "$RG" \
  --query workspaceUrl -o tsv)
echo "   Workspace URL: $WS_URL"
echo

echo "5️⃣  Creating terraform.tfvars for Databricks provider..."
mkdir -p terraform/databricks-rbac
cat > terraform/databricks-rbac/terraform.tfvars <<EOF
azure_client_id     = "$CLIENT_ID"
azure_client_secret = "$CLIENT_SECRET"
azure_tenant_id     = "$TENANT_ID"
subscription_id     = "$SUBSCRIPTION_ID"
databricks_host     = "https://${WS_URL}"
EOF
echo "   ✅  Updated terraform/databricks-rbac/terraform.tfvars"
echo

echo "6️⃣  Waiting for permissions to propagate (60 seconds)..."
sleep 60
echo "   ✅  Delay completed"
echo 

echo "🎉  Service Principal setup complete!"
echo "   • Credentials are in databricks-sp.json"
echo "   • terraform.tfvars has been updated"
echo "   • Run './deploy.sh --dbrbac' to deploy Databricks RBAC"