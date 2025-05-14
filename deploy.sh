#!/bin/bash

# Configuration
SUBSCRIPTION_ID="c1508b64-fb45-46f5-bf88-511ae65059d0"

# Check for --nuke flag
if [ "$1" == "--nuke" ]; then
    echo "Preparing for clean deployment..."
    
    # Clean up Terraform state
    cd terraform
    rm -rf .terraform terraform.tfstate terraform.tfstate.backup 2>/dev/null || true
    terraform init
    cd ..
fi

# Apply Terraform for core resources first
echo "Creating/updating core infrastructure..."
cd terraform
terraform init

# Apply only resource group and storage account first
echo "Creating resource group and storage account..."
terraform apply -auto-approve -target=azurerm_resource_group.rg -target=azurerm_storage_account.sa -target=random_string.rg_suffix -target=random_string.storage_suffix

# Get the dynamically created resource names from Terraform outputs
echo "Getting resource names from Terraform..."
RESOURCE_GROUP=$(terraform output -raw resource_group_name)
APP_NAME=$(terraform output -raw web_app_name)
DATABRICKS_NAME=$(terraform output -raw databricks_workspace_name 2>/dev/null || echo "")
STORAGE_ACCOUNT=$(terraform output -raw storage_account_name)

echo "Using resource group: $RESOURCE_GROUP"
echo "Using app name: $APP_NAME"
echo "Using storage account: $STORAGE_ACCOUNT"
echo "Using databricks name: $DATABRICKS_NAME"

# Wait for storage account to be fully provisioned
echo "Waiting for storage account to be fully provisioned..."
MAX_RETRIES=15
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if az resource show --resource-group $RESOURCE_GROUP --name $STORAGE_ACCOUNT --resource-type "Microsoft.Storage/storageAccounts" &>/dev/null; then
        echo "Storage account exists in Azure!"
        break
    fi
    
    RETRY_COUNT=$((RETRY_COUNT+1))
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo "Storage account existence check timed out after $MAX_RETRIES retries."
        echo "Continuing with deployment anyway..."
        break
    fi
    
    echo "Storage account not yet visible in Azure. Waiting 20 seconds... (Attempt $RETRY_COUNT/$MAX_RETRIES)"
    sleep 20
done

# Apply the rest of Terraform
echo "Creating remaining infrastructure..."
terraform apply -auto-approve

# Refresh the outputs after everything is created
echo "Refreshing resource names from Terraform..."
RESOURCE_GROUP=$(terraform output -raw resource_group_name)
APP_NAME=$(terraform output -raw web_app_name)
DATABRICKS_NAME=$(terraform output -raw databricks_workspace_name)
STORAGE_ACCOUNT=$(terraform output -raw storage_account_name)

echo "Using refreshed resource names:"
echo "  Resource group: $RESOURCE_GROUP"
echo "  App name: $APP_NAME"
echo "  Storage account: $STORAGE_ACCOUNT"
echo "  Databricks name: $DATABRICKS_NAME"

cd ..

# Deploy the app
echo "Building app..."
cd src

# Clean up old publish directory first
rm -rf ./publish

# Create fresh publish
dotnet publish -c Release -o ./publish

echo "Creating deployment package..."
cd publish

# Clean up any old deployment packages
rm -f ../deploy.zip 2>/dev/null || true

# Create a fresh package (exclude nested publish directories)
zip -r ../deploy.zip . -x "publish/*" "*/publish/*"
cd ..

# Wait a bit for resources to be fully provisioned
echo "Waiting for resources to be fully provisioned..."
sleep 30

# Check if app exists before deploying
echo "Checking if app exists before deploying..."
if az webapp show --resource-group $RESOURCE_GROUP --name $APP_NAME &>/dev/null; then
    echo "Deploying to Azure..."
    az webapp deploy --resource-group $RESOURCE_GROUP \
      --name $APP_NAME \
      --src-path ./deploy.zip \
      --type zip
else
    echo "Warning: Web app $APP_NAME not found in resource group $RESOURCE_GROUP"
    echo "This may be normal if Terraform is still provisioning resources."
    echo "Try running the following command when resources are ready:"
    echo "az webapp deploy --resource-group $RESOURCE_GROUP --name $APP_NAME --src-path ./src/deploy.zip --type zip"
fi

# Display Databricks workspace information (if available)
if [ -n "$DATABRICKS_NAME" ]; then
    echo "Checking Databricks workspace information..."
    if az databricks workspace show --resource-group $RESOURCE_GROUP --name $DATABRICKS_NAME &>/dev/null; then
        echo "Databricks workspace URL:"
        DATABRICKS_URL=$(az databricks workspace show --resource-group $RESOURCE_GROUP --name $DATABRICKS_NAME --query workspaceUrl -o tsv)
        echo "https://$DATABRICKS_URL"
    else
        echo "Databricks workspace not yet available. It may still be provisioning."
    fi
fi

# Setup Databricks access
if [ -n "$DATABRICKS_NAME" ]; then
    echo "Setting up Databricks access..."
    
    # Get current user principal ID dynamically
    PRINCIPAL_ID=$(az ad signed-in-user show --query id -o tsv)
    USER_EMAIL=$(az ad signed-in-user show --query userPrincipalName -o tsv)
    
    # Get Databricks workspace ID
    DATABRICKS_ID=$(az databricks workspace show \
      --resource-group $RESOURCE_GROUP \
      --name $DATABRICKS_NAME \
      --query id -o tsv)
    
    echo "Databricks access configured."
    
    # Wait for permissions to propagate
    echo "Waiting 30 seconds for permissions to propagate..."
    sleep 30
fi

# Create Databricks cluster
if [ -n "$DATABRICKS_NAME" ]; then
    echo "Creating Databricks cluster..."
    
    # Get workspace URL
    DATABRICKS_URL=$(az databricks workspace show \
      --resource-group $RESOURCE_GROUP \
      --name $DATABRICKS_NAME \
      --query workspaceUrl -o tsv)
    
    # Get Azure AD token
    AAD_TOKEN=$(az account get-access-token --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query accessToken -o tsv)
    
    # Get management token
    MGMT_TOKEN=$(az account get-access-token \
      --resource https://management.core.windows.net/ \
      --query accessToken -o tsv)
    
    # Check if cluster already exists
    EXISTING_CLUSTERS=$(curl -s -X GET https://${DATABRICKS_URL}/api/2.0/clusters/list \
      -H "Authorization: Bearer $AAD_TOKEN" \
      -H "X-Databricks-Azure-SP-Management-Token: $MGMT_TOKEN" \
      -H "X-Databricks-Azure-Workspace-Resource-Id: $DATABRICKS_ID" \
      -H "Content-Type: application/json" | jq -r '.clusters[] | select(.cluster_name=="iot-minimal-cluster") | .cluster_id' 2>/dev/null)
    
    if [ -z "$EXISTING_CLUSTERS" ]; then
        echo "Creating new single-node cluster..."
        
        # Create minimal single-node cluster
        CLUSTER_RESPONSE=$(curl -s -X POST https://${DATABRICKS_URL}/api/2.0/clusters/create \
          -H "Authorization: Bearer $AAD_TOKEN" \
          -H "X-Databricks-Azure-SP-Management-Token: $MGMT_TOKEN" \
          -H "X-Databricks-Azure-Workspace-Resource-Id: $DATABRICKS_ID" \
          -H "Content-Type: application/json" \
          -d '{
            "cluster_name": "iot-minimal-cluster",
            "spark_version": "13.3.x-scala2.12",
            "node_type_id": "Standard_F4s",
            "num_workers": 0,
            "autotermination_minutes": 120,
            "spark_conf": {
              "spark.databricks.cluster.profile": "singleNode",
              "spark.master": "local[*]"
            }
          }')
        
        CLUSTER_ID=$(echo $CLUSTER_RESPONSE | jq -r '.cluster_id')
        echo "Cluster response: $CLUSTER_RESPONSE"
        echo "Cluster created with ID: $CLUSTER_ID"
        echo "Cluster will auto-terminate after 120 minutes of inactivity"
    else
        echo "Cluster 'iot-minimal-cluster' already exists with ID: $EXISTING_CLUSTERS"
        CLUSTER_ID=$EXISTING_CLUSTERS
    fi
fi

# Generate SAS token for storage - FIXED FOR macOS
if [ -n "$STORAGE_ACCOUNT" ]; then
    echo "Generating SAS token for storage access..."
    
    # Get storage key
    STORAGE_KEY=$(az storage account keys list \
      --resource-group $RESOURCE_GROUP \
      --account-name $STORAGE_ACCOUNT \
      --query "[0].value" -o tsv)
    
    # Generate SAS token - Fixed for macOS date command
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        END_DATE=$(date -v+1y -u "+%Y-%m-%dT%H:%MZ")
        START_DATE=$(date -v-1d -u "+%Y-%m-%dT%H:%MZ")
    else
        # Linux
        END_DATE=$(date -u -d "1 year" '+%Y-%m-%dT%H:%MZ')
        START_DATE=$(date -u -d "yesterday" '+%Y-%m-%dT%H:%MZ')
    fi
    
    SAS_TOKEN=$(az storage container generate-sas \
      --account-name $STORAGE_ACCOUNT \
      --account-key $STORAGE_KEY \
      --name rawdata \
      --permissions acdlrw \
      --start $START_DATE \
      --expiry $END_DATE \
      --output tsv)
    
    echo "SAS Token generated successfully"
    
    # Save credentials to file
    cd ..
    cat > databricks_config.txt <<EOL
Databricks Configuration
========================
Workspace URL: https://$DATABRICKS_URL
Cluster ID: $CLUSTER_ID
Storage Account: $STORAGE_ACCOUNT
Container: rawdata
SAS Token: $SAS_TOKEN

To access Databricks:
1. Go to: https://$DATABRICKS_URL
2. Sign in with your Azure AD account ($USER_EMAIL)
3. Navigate to Compute > All Clusters
4. Find the cluster named: iot-minimal-cluster
5. Start the cluster if it's not running

If you see "Unable to view page" error:
- Run: az login
- Then visit the URL again
EOL
    
    echo "Configuration saved to databricks_config.txt"
    
    # Create Databricks notebook
    if [ -n "$DATABRICKS_NAME" ] && [ -n "$CLUSTER_ID" ]; then
        echo "Creating Databricks notebook..."
        
        # Get user email for the notebook path
        USER_EMAIL=$(az ad signed-in-user show --query userPrincipalName -o tsv)
        
        # Check if user folder exists
        echo "Checking if user folder exists..."
        USER_FOLDER="/Users/${USER_EMAIL}"
        
        FOLDER_CHECK=$(curl -s -X GET https://${DATABRICKS_URL}/api/2.0/workspace/get-status \
          -H "Authorization: Bearer $AAD_TOKEN" \
          -H "X-Databricks-Azure-SP-Management-Token: $MGMT_TOKEN" \
          -H "X-Databricks-Azure-Workspace-Resource-Id: $DATABRICKS_ID" \
          -H "Content-Type: application/json" \
          -d "{\"path\": \"${USER_FOLDER}\"}")
        
        # If folder doesn't exist, create it
        if [[ $FOLDER_CHECK == *"RESOURCE_DOES_NOT_EXIST"* ]]; then
            echo "Creating user folder in Databricks..."
            USER_FOLDER_JSON="{
      \"path\": \"${USER_FOLDER}\"
    }"
            
            FOLDER_RESPONSE=$(curl -s -X POST https://${DATABRICKS_URL}/api/2.0/workspace/mkdirs \
              -H "Authorization: Bearer $AAD_TOKEN" \
              -H "X-Databricks-Azure-SP-Management-Token: $MGMT_TOKEN" \
              -H "X-Databricks-Azure-Workspace-Resource-Id: $DATABRICKS_ID" \
              -H "Content-Type: application/json" \
              -d "$USER_FOLDER_JSON")
            
            echo "Folder creation response: $FOLDER_RESPONSE"
            
            # Wait a bit for folder to be created
            sleep 5
        else
            echo "User folder already exists"
        fi
        
        # Use shared location instead of user folder
        NOTEBOOK_PATH="/Shared/iot-data-analysis"
        
        # Create notebook content
        NOTEBOOK_PYTHON_CODE="# Configuration
storage_account_name = \"$STORAGE_ACCOUNT\"
container_name = \"rawdata\"
sas_token = \"?$SAS_TOKEN\"

# Configure access using a SAS token
spark.conf.set(f\"fs.azure.sas.{container_name}.{storage_account_name}.blob.core.windows.net\", sas_token)

# Use blob storage format
from datetime import datetime
now = datetime.utcnow()
year, month, day, hour = now.strftime(\"%Y\"), now.strftime(\"%m\"), now.strftime(\"%d\"), now.strftime(\"%H\")

# Use blob storage path format
path = f\"wasbs://{container_name}@{storage_account_name}.blob.core.windows.net/{year}/{month}/{day}/{hour}/\"
print(f\"Looking for files in: {path}\")

# Try to access and process the data
try:
    # List files in the path
    files = dbutils.fs.ls(path)
    print(f\"Found {len(files)} files\")
    
    # Show the files
    for file in files:
        print(f\" - {file.path}\")
    
    # Read the data
    df = spark.read.json(path)
    
    # Show the data
    print(\"Sample data:\")
    display(df)
    
    # Create temp view for SQL
    df.createOrReplaceTempView(\"iot_data\")
    
    # Run SQL analysis
    print(\"Analytics results:\")
    results = spark.sql(\"\"\"
        SELECT 
            deviceId, 
            COUNT(*) as readings,
            AVG(temperature) as avg_temperature, 
            AVG(humidity) as avg_humidity
        FROM iot_data
        GROUP BY deviceId
    \"\"\")
    display(results)
except Exception as e:
    print(f\"Error: {str(e)}\")
    
    # Try listing the root container
    try:
        print(\"\\nTrying to list container root to see what's available...\")
        root = f\"wasbs://{container_name}@{storage_account_name}.blob.core.windows.net/\"
        root_files = dbutils.fs.ls(root)
        print(\"Found in container root:\")
        for file in root_files:
            print(f\" - {file.path}\")
    except Exception as e2:
        print(f\"Error listing container: {str(e2)}\")"
        
        # Base64 encode the content
        ENCODED_CONTENT=$(echo -n "$NOTEBOOK_PYTHON_CODE" | base64)
        
        # Create notebook via API - note the path without /Workspace prefix
        NOTEBOOK_JSON="{
  \"path\": \"${NOTEBOOK_PATH}\",
  \"language\": \"PYTHON\",
  \"content\": \"$ENCODED_CONTENT\",
  \"overwrite\": true,
  \"format\": \"SOURCE\"
}"
        
        echo "Creating notebook in shared location..."
        NOTEBOOK_RESPONSE=$(curl -s -X POST https://${DATABRICKS_URL}/api/2.0/workspace/import \
          -H "Authorization: Bearer $AAD_TOKEN" \
          -H "X-Databricks-Azure-SP-Management-Token: $MGMT_TOKEN" \
          -H "X-Databricks-Azure-Workspace-Resource-Id: $DATABRICKS_ID" \
          -H "Content-Type: application/json" \
          -d "$NOTEBOOK_JSON")
        
        echo "Notebook response: $NOTEBOOK_RESPONSE"
        
        # If shared location fails, try user location anyway
        if [[ $NOTEBOOK_RESPONSE == *"error"* ]]; then
            echo "Failed to create in shared location, attempting user location..."
            USER_EMAIL=$(az ad signed-in-user show --query userPrincipalName -o tsv)
            USER_NOTEBOOK_PATH="/Users/${USER_EMAIL}/iot-data-analysis"
            
            NOTEBOOK_JSON="{
  \"path\": \"${USER_NOTEBOOK_PATH}\",
  \"language\": \"PYTHON\",
  \"content\": \"$ENCODED_CONTENT\",
  \"overwrite\": true,
  \"format\": \"SOURCE\"
}"
            
            NOTEBOOK_RESPONSE=$(curl -s -X POST https://${DATABRICKS_URL}/api/2.0/workspace/import \
              -H "Authorization: Bearer $AAD_TOKEN" \
              -H "X-Databricks-Azure-SP-Management-Token: $MGMT_TOKEN" \
              -H "X-Databricks-Azure-Workspace-Resource-Id: $DATABRICKS_ID" \
              -H "Content-Type: application/json" \
              -d "$NOTEBOOK_JSON")
            
            echo "User location attempt response: $NOTEBOOK_RESPONSE"
            NOTEBOOK_PATH=$USER_NOTEBOOK_PATH
        fi
        
        echo ""
        echo "========================================"
        echo "Databricks Setup Complete!"
        echo "========================================"
        echo "1. Workspace URL: https://$DATABRICKS_URL"
        echo "2. Cluster: iot-minimal-cluster (ID: $CLUSTER_ID)"
        echo "3. Notebook location: ${NOTEBOOK_PATH}"
        echo "4. Configuration saved to: databricks_config.txt"
        echo ""
        echo "To access the notebook:"
        echo "- Go to Databricks workspace"
        echo "- Navigate to: ${NOTEBOOK_PATH}"
        echo "- Or create it manually if not found"
        echo ""
        echo "Note: Cluster may take 5-10 minutes to start up"
        echo "========================================"
    fi
    
    cd src
fi

# Optionally tail logs if web app exists
if az webapp show --resource-group $RESOURCE_GROUP --name $APP_NAME &>/dev/null; then
    echo "Tailing API logs..."
    az webapp log tail --resource-group $RESOURCE_GROUP --name $APP_NAME
else
    echo "Web app not yet available for log tailing."
fi

echo "Deployment script completed."