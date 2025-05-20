#!/bin/bash
# destroy_all.sh - Complete cleanup script

set -e # Exit immediately if a command exits with a non-zero status.

echo "-----------------------------------------------------------------------"
echo " WARNING: Destructive Operation!"
echo "-----------------------------------------------------------------------"
echo "This script will:"
echo "1. Run Terraform destroy to gracefully remove resources"
echo "2. Delete any Service Principals created for this project"
echo "3. Delete the Azure Resource Group 'niotv1-dev-rg' and ALL its resources."
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

# First destroy Databricks RBAC (which depends on the workspace)
if [ -d "terraform/databricks-rbac" ]; then
    echo "Destroying Databricks RBAC configuration..."
    (cd terraform/databricks-rbac && terraform destroy --auto-approve) || echo "RBAC destruction failed, but continuing..."
fi

# Then destroy main infrastructure
echo "Destroying main infrastructure..."
(cd terraform && terraform destroy --auto-approve) || echo "Main infrastructure destruction failed, but continuing..."

# Add this section to Step 1 of your destroy_all.sh script

# Handle Key Vault special case - purge any soft-deleted vaults
echo "Checking for soft-deleted Key Vaults to purge..."
VAULT_NAME="niotv1-dev-kv"

# Try to purge any soft-deleted key vault
if az keyvault list-deleted --query "[?name=='$VAULT_NAME'].name" -o tsv | grep -q "$VAULT_NAME"; then
  echo "Found soft-deleted Key Vault: $VAULT_NAME. Purging..."
  az keyvault purge --name "$VAULT_NAME" || echo "Failed to purge Key Vault, but continuing..."
fi

# Try to update Key Vault access policies if it exists
if az keyvault show --name "$VAULT_NAME" --resource-group "$RESOURCE_GROUP_NAME" &>/dev/null; then
  echo "Key Vault exists, updating access policies..."
  CURRENT_USER_OID=$(az ad signed-in-user show --query id -o tsv)
  
  az keyvault set-policy --name "$VAULT_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --object-id "$CURRENT_USER_OID" \
    --secret-permissions get list set delete backup restore recover purge \
    --key-permissions get list create delete backup restore recover purge \
    --certificate-permissions get list create delete backup restore recover purge \
    || echo "Failed to update Key Vault policies, but continuing..."
fi

# --- Step 2: Delete any Service Principals ---
echo ""
echo "Step 2: Deleting Service Principals..."

SP_NAME="databricks-niotv1-sp"
SP_ID=$(az ad sp list --display-name "$SP_NAME" --query '[].appId' -o tsv 2>/dev/null || echo "")

if [ -n "$SP_ID" ]; then
    echo "↳ Found Service Principal: $SP_NAME (ID: $SP_ID). Deleting..."
    az ad sp delete --id "$SP_ID" || echo "SP deletion failed, but continuing..."
    echo "✅ Service Principal deleted"
else
    echo "↳ No Service Principal found with name: $SP_NAME"
fi

# --- Step 3: Azure Resource Group Deletion ---
# Define your Azure Resource Group name here for easy modification if needed.
RESOURCE_GROUP_NAME="niotv1-dev-rg"

echo ""
echo "Step 3: Handling Azure Resource Group '$RESOURCE_GROUP_NAME'..."

# Check if the resource group actually exists in Azure
echo "Checking if Azure Resource Group '$RESOURCE_GROUP_NAME' currently exists..."
GROUP_EXISTS_OUTPUT=$(az group exists --name "$RESOURCE_GROUP_NAME" --output tsv 2>/dev/null || echo "false")

if [ "$GROUP_EXISTS_OUTPUT" == "true" ]; then
    echo "Resource Group '$RESOURCE_GROUP_NAME' found. Attempting to delete it now."
    echo "This step can take several minutes as it waits for Azure to confirm deletion. Please be patient."
    
    # Delete the Azure Resource Group.
    if az group delete --name "$RESOURCE_GROUP_NAME" --yes; then
        echo "Azure Resource Group '$RESOURCE_GROUP_NAME' and all its resources deleted successfully."
    else
        echo "ERROR: Failed to delete Azure Resource Group '$RESOURCE_GROUP_NAME'."
        echo "Please check the Azure portal or Azure CLI logs for more details."
        echo "Continuing with local file cleanup, but Azure resources might still exist."
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
echo "2. Run './create_databricks_sp.sh niotv1-dev-rg niotv1-dev-databricks' to setup the Service Principal"
echo "3. Run './deploy.sh --dbrbac' to deploy Databricks RBAC"
echo "4. Run './deploy.sh --api' to deploy the API"
echo ""
echo "Or simply run './deploy.sh' to deploy everything at once."