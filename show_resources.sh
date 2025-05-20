#!/bin/bash
# show_resources.sh - A script to display all Azure resources

# Set error handling
set -e

# Check if Azure CLI is installed
command -v az >/dev/null 2>&1 || { echo "Azure CLI not found. Please install it."; exit 1; }

# Check if logged in to Azure
az account show >/dev/null 2>&1 || { 
    echo "Not logged in to Azure. Initiating login..."
    az login
}

# Display account and subscription info
echo "======================================================================="
echo "AZURE ACCOUNT INFORMATION"
echo "======================================================================="
az account show --output table

echo -e "\n"
echo "======================================================================="
echo "RESOURCE GROUPS"
echo "======================================================================="
az group list --output table

# Get the IoT resource group name (assuming it exists)
IOT_RG="niotv1-dev-rg"

echo -e "\n"
echo "======================================================================="
echo "ALL RESOURCES IN '$IOT_RG'"
echo "======================================================================="
az resource list --resource-group "$IOT_RG" --output table

# Check if the databricks resource group exists
DATABRICKS_RG="databricks-rg-niotv1-dev-rg"
if az group show --name "$DATABRICKS_RG" &>/dev/null; then
    echo -e "\n"
    echo "======================================================================="
    echo "ALL RESOURCES IN '$DATABRICKS_RG'"
    echo "======================================================================="
    az resource list --resource-group "$DATABRICKS_RG" --output table
fi

echo -e "\n"
echo "======================================================================="
echo "STORAGE ACCOUNTS"
echo "======================================================================="
az storage account list --output table

echo -e "\n"
echo "======================================================================="
echo "APP SERVICES"
echo "======================================================================="
az webapp list --output table

echo -e "\n"
echo "======================================================================="
echo "DATABRICKS WORKSPACES"
echo "======================================================================="
az databricks workspace list --output table

echo -e "\n"
echo "======================================================================="
echo "SERVICE PRINCIPALS"
echo "======================================================================="
echo "Listing Service Principal: databricks-niotv1-sp"
az ad sp list --display-name databricks-niotv1-sp --output table

# Get the Service Principal ID
SP_ID=$(az ad sp list --display-name databricks-niotv1-sp --query "[0].appId" -o tsv 2>/dev/null)

if [ -n "$SP_ID" ]; then
    echo -e "\n"
    echo "======================================================================="
    echo "ROLE ASSIGNMENTS FOR SERVICE PRINCIPAL: $SP_ID"
    echo "======================================================================="
    az role assignment list --assignee "$SP_ID" --output table
else
    echo "No Service Principal found with name 'databricks-niotv1-sp'."
fi

# Get Databricks workspace ID if it exists
DATABRICKS_ID=$(az databricks workspace list --query "[0].id" -o tsv 2>/dev/null)

if [ -n "$DATABRICKS_ID" ]; then
    echo -e "\n"
    echo "======================================================================="
    echo "DETAILED DATABRICKS WORKSPACE INFO"
    echo "======================================================================="
    az databricks workspace show --ids "$DATABRICKS_ID" --output table
fi

echo -e "\n"
echo "======================================================================="
echo "STORAGE CONTAINERS"
echo "======================================================================="
# Get a list of storage accounts
STORAGE_ACCOUNTS=$(az storage account list --query "[].name" -o tsv)

for acct in $STORAGE_ACCOUNTS; do
  # Figure out which RG this account lives in
  RG=$(az storage account show \
        --name "$acct" \
        --query resourceGroup \
        -o tsv)

  echo "Storage Account: $acct (ResourceGroup: $RG)"
  echo "----------------------------------------------------------------------"

  # Skip Databricks-managed resource groups entirely
  if [[ "$RG" == databricks-rg-* ]]; then
    echo "  ➔ Skipping, managed by Databricks (no key access)."
    echo ""
    continue
  fi

  # Try to get a key; if it fails we'll skip
  set +e
  KEY=$(az storage account keys list \
          --account-name "$acct" \
          --query "[0].value" \
          -o tsv)
  RET=$?
  set -e

  if [ $RET -ne 0 ]; then
    echo "  ➔ Could not list keys (insufficient permissions), skipping containers."
    echo ""
    continue
  fi

  # Now that we have a key, list containers
  az storage container list \
    --account-name "$acct" \
    --account-key "$KEY" \
    --output table
  echo ""
done

echo -e "\n"
echo "======================================================================="
echo "RESOURCE SUMMARY"
echo "======================================================================="
echo "Total Resource Groups: $(az group list --query "length(@)" -o tsv)"
echo "Total Resources: $(az resource list --query "length(@)" -o tsv)"
echo "Total Storage Accounts: $(az storage account list --query "length(@)" -o tsv)"
echo "Total App Services: $(az webapp list --query "length(@)" -o tsv)"
echo "Total Databricks Workspaces: $(az databricks workspace list --query "length(@)" -o tsv)"

echo -e "\n"
echo "Resource listing complete!"
