#!/bin/bash

# Configuration
RESOURCE_GROUP="iot-azure-rg"
APP_NAME="iot-azure-api-app-ned"

# Check for --nuke flag
if [ "$1" == "--nuke" ]; then
    echo "Destroying infrastructure..."
    cd terraform
    terraform destroy -auto-approve || true
    
    echo "Rebuilding infrastructure..."
    terraform init
    terraform apply -auto-approve
    
    # Check if infrastructure was created successfully
    if ! az group show --name $RESOURCE_GROUP &>/dev/null; then
        echo "Error: Failed to create resource group. Creating manually..."
        az group create --name $RESOURCE_GROUP --location eastus2
    fi
    
    # Check if web app was created
    if ! az webapp show --name $APP_NAME --resource-group $RESOURCE_GROUP &>/dev/null; then
        echo "Creating App Service Plan and Web App manually..."
        az appservice plan create --name iot-azure-asp --resource-group $RESOURCE_GROUP --sku B1 --is-linux
        az webapp create --name $APP_NAME --resource-group $RESOURCE_GROUP --plan "iot-azure-asp" --runtime "DOTNET|8.0"
        
        # Add app settings
        az webapp config appsettings set --resource-group $RESOURCE_GROUP --name $APP_NAME \
          --settings "APP_API_KEY=SuperSecretKey123!ChangeMeLater" \
          "STORAGE_ACCOUNT_NAME=iotlearn2024ned" \
          "STORAGE_CONTAINER_NAME=rawdata"
          
        # Create storage account if it doesn't exist
        if ! az storage account show --name iotlearn2024ned --resource-group $RESOURCE_GROUP &>/dev/null; then
            echo "Creating storage account manually..."
            az storage account create --name iotlearn2024ned --resource-group $RESOURCE_GROUP --location eastus2 --sku Standard_LRS
            az storage container create --name rawdata --account-name iotlearn2024ned --auth-mode login
            
            # Setup managed identity and permissions for storage
            az webapp identity assign --name $APP_NAME --resource-group $RESOURCE_GROUP
            PRINCIPAL_ID=$(az webapp identity show --name $APP_NAME --resource-group $RESOURCE_GROUP --query principalId -o tsv)
            STORAGE_ID=$(az storage account show --name iotlearn2024ned --resource-group $RESOURCE_GROUP --query id -o tsv)
            az role assignment create --assignee $PRINCIPAL_ID --role "Storage Blob Data Contributor" --scope $STORAGE_ID
        fi
    fi
    cd ..
fi

# Deploy the app
echo "Building app..."
cd src
dotnet publish -c Release -o ./publish

echo "Creating deployment package..."
cd publish
zip -r ../deploy.zip *
cd ..

echo "Deploying to Azure..."
az webapp deployment source config-zip \
  --resource-group $RESOURCE_GROUP \
  --name $APP_NAME \
  --src ./publish/deploy.zip

echo "Deployment complete! Tailing logs..."
az webapp log tail --resource-group $RESOURCE_GROUP --name $APP_NAME