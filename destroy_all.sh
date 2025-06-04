#!/bin/bash
# destroy_all.sh - Complete cleanup script (macOS compatible)

set -e # Exit immediately if a command exits with a non-zero status.

# Load environment variables from .env file
if [ -f ".env" ]; then
    echo "Loading environment variables from .env..."
    source .env
    export TF_VAR_api_key
    export AZURE_CLIENT_ID
    export AZURE_CLIENT_SECRET
    export AZURE_TENANT_ID
    export AZURE_SUBSCRIPTION_ID
    export OWNER_EMAIL
    echo "✅ Environment variables loaded"
else
    echo "⚠️  No .env file found"
fi

# Get dynamic values from Terraform outputs if available, otherwise use defaults
PROJECT_NAME="${PROJECT_NAME:-niotv1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
RESOURCE_GROUP_NAME="${PROJECT_NAME}-${ENVIRONMENT}-rg"
VAULT_NAME="${PROJECT_NAME}-${ENVIRONMENT}-kv"
WORKSPACE_NAME="${PROJECT_NAME}-${ENVIRONMENT}-databricks"

# Try to get current subscription and tenant if not set
if [ -z "$AZURE_SUBSCRIPTION_ID" ]; then
    AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null || echo "")
fi
if [ -z "$AZURE_TENANT_ID" ]; then
    AZURE_TENANT_ID=$(az account show --query tenantId -o tsv 2>/dev/null || echo "")
fi

echo "-----------------------------------------------------------------------"
echo " WARNING: Destructive Operation!"
echo "-----------------------------------------------------------------------"
echo "This script will:"
echo "1. Run Terraform destroy to gracefully remove resources"
echo "2. Delete any Service Principals created for this project"
echo "3. Delete the Azure Resource Group '$RESOURCE_GROUP_NAME' and ALL its resources."
echo "4. Delete ALL local Terraform state files, working directories, and lock files."
echo "5. Remove credentials files (databricks-sp.json and terraform.tfvars)."
echo ""
echo "This operation is intended for a COMPLETE reset to a clean slate."
echo "It CANNOT BE UNDONE."
echo "Make sure this script is run from the root directory of your project."
echo "-----------------------------------------------------------------------"

# Ask for confirmation - requiring an exact "yes"
read -p "Are you ABSOLUTELY SURE you want to wipe everything? Type 'yes' to confirm: " CONFIRM

# Convert to lowercase for robust comparison
if [ "$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')" != "yes" ]; then
    echo "Operation cancelled by user."
    exit 0
fi

echo ""
echo "Proceeding with deletion..."

# --- Step 1: Run terraform destroy first to gracefully remove resources ---
echo ""
echo "Step 1: Running Terraform destroy to gracefully remove resources..."

# Skip Databricks RBAC destruction entirely - let Resource Group deletion handle it
echo "Skipping Databricks RBAC destruction (will be cleaned up with Resource Group)..."

# Destroy main infrastructure
echo "Destroying main infrastructure..."
echo "Initializing main Terraform..."
(cd terraform && terraform init -upgrade) || echo "Main init failed, but continuing..."

# Remove Key Vault from Terraform state to avoid the long deletion wait
echo "Removing Key Vault from Terraform state (will be deleted with Resource Group)..."
(cd terraform && terraform state list 2>/dev/null | grep -q "azurerm_key_vault.kv" && terraform state rm azurerm_key_vault.kv) || echo "Key Vault not in state"
(cd terraform && terraform state list 2>/dev/null | grep -q "azurerm_key_vault_secret.databricks_app_id" && terraform state rm azurerm_key_vault_secret.databricks_app_id) || echo "Secret not in state"
(cd terraform && terraform state list 2>/dev/null | grep -q "azurerm_key_vault_secret.tenant_id" && terraform state rm azurerm_key_vault_secret.tenant_id) || echo "Secret not in state"

# Use terraform destroy without timeout (let it run)
echo "Running terraform destroy (skipping refresh to avoid storage account errors)..."
(cd terraform && terraform destroy -refresh=false --auto-approve) || echo "Main infrastructure destruction failed, but continuing..."

# Skip Key Vault purging since it's very slow - just note it
echo "Checking for soft-deleted Key Vaults..."
if az keyvault list-deleted --query "[?name=='$VAULT_NAME'].name" -o tsv 2>/dev/null | grep -q "$VAULT_NAME"; then
  echo "⚠️  Found soft-deleted Key Vault: $VAULT_NAME"
  echo "   This will be automatically purged by Azure in 90 days, or you can manually purge it later."
  echo "   To manually purge: az keyvault purge --name $VAULT_NAME"
  echo "   Skipping automatic purge to avoid long wait times..."
else
  echo "No soft-deleted Key Vaults found"
fi

# --- Step 2: Delete any Service Principals ---
echo ""
echo "Step 2: Deleting Service Principals..."

# Check for multiple possible SP names using dynamic naming
SP_NAMES=(
    "databricks-${PROJECT_NAME}-sp" 
    "databricks-${WORKSPACE_NAME}"
    "databricks-${PROJECT_NAME}-${ENVIRONMENT}-databricks"
)

for SP_NAME in "${SP_NAMES[@]}"; do
    SP_ID=$(az ad sp list --display-name "$SP_NAME" --query '[].appId' -o tsv 2>/dev/null || echo "")
    
    if [ -n "$SP_ID" ]; then
        echo "↳ Found Service Principal: $SP_NAME (ID: $SP_ID). Deleting..."
        az ad sp delete --id "$SP_ID" || echo "SP deletion failed for $SP_NAME, but continuing..."
        echo "✅ Service Principal $SP_NAME deleted"
    else
        echo "↳ No Service Principal found with name: $SP_NAME"
    fi
done

# --- Step 3: Azure Resource Group Deletion ---
echo ""
echo "Step 3: Handling Azure Resource Group '$RESOURCE_GROUP_NAME'..."

# Check if the resource group actually exists in Azure
echo "Checking if Azure Resource Group '$RESOURCE_GROUP_NAME' currently exists..."
GROUP_EXISTS_OUTPUT=$(az group exists --name "$RESOURCE_GROUP_NAME" --output tsv 2>/dev/null || echo "false")

if [ "$GROUP_EXISTS_OUTPUT" == "true" ]; then
    echo "Resource Group '$RESOURCE_GROUP_NAME' found. Starting deletion..."
    echo "⚠️  This may take 10-20 minutes for Databricks workspaces. Please be patient."
    
    # Start the deletion without timeout - let it complete naturally
    echo "Starting Resource Group deletion (this will run until completion)..."
    if az group delete --name "$RESOURCE_GROUP_NAME" --yes; then
        echo "✅ Azure Resource Group '$RESOURCE_GROUP_NAME' and all its resources deleted successfully."
    else
        echo "❌ Resource Group deletion failed."
        echo "   Check Azure portal to see current status."
        echo "   You may need to manually delete it from the portal."
    fi
else
    echo "Azure Resource Group '$RESOURCE_GROUP_NAME' not found (it might have been deleted already)."
    echo "Skipping Azure deletion step."
fi

# --- Step 4: Local Terraform and Credential File Cleanup ---
echo ""
echo "Step 4: Cleaning local Terraform project files, API app services files, and credentials..."

# Remove specific credential files
echo "Removing credential files..."
rm -f databricks-sp.json
rm -f terraform/databricks-rbac/terraform.tfvars
rm -f sp_credentials.json

# Clean up App Service deployment files
echo "Cleaning up App Service deployment files..."
rm -f app.zip
rm -f src/ingest_api/app.zip  # In case it's created in the API directory
rm -rf src/ingest_api/bin     # Remove build outputs
rm -rf src/ingest_api/obj     # Remove build outputs

# Clean up terraform directories and state files
echo "Cleaning up Terraform files..."
find . -type d -name ".terraform" -prune -exec echo "Deleting directory: {}" \; -exec rm -rf {} \;
find . -type f -name "terraform.tfstate*" -exec echo "Deleting file: {}" \; -exec rm -f {} \;
find . -type f -name ".terraform.lock.hcl" -exec echo "Deleting file: {}" \; -exec rm -f {} \;

# --- Step 5: Final cleanup ---
echo ""
echo "Step 5: Final cleanup..."

# Remove any other temporary files that might have been created
rm -f /tmp/sp_response.json

echo ""
echo "-----------------------------------------------------------------------"
echo " Clean-up script finished."
echo "-----------------------------------------------------------------------"
echo "All resources should now be completely removed."
echo "Your project workspace is clean. You can now rebuild everything:"
echo ""
echo "1. Run './deploy.sh --infra' to deploy infrastructure"
echo "2. Run './create_databricks_sp.sh $RESOURCE_GROUP_NAME $WORKSPACE_NAME' to setup the Service Principal"
echo "3. Run './deploy.sh --dbrbac' to deploy Databricks RBAC"
echo "4. Run './deploy.sh --api' to deploy the API"
echo ""
echo "Or simply run './deploy.sh' to deploy everything at once."