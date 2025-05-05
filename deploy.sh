#!/bin/bash

# Configuration
RESOURCE_GROUP="iot-azure-rg"
APP_NAME="iot-azure-api-app-ned"

# Check for --nuke flag
if [ "$1" == "--nuke" ]; then
    echo "Destroying infrastructure..."
    cd terraform
    terraform destroy -auto-approve
    
    echo "Rebuilding infrastructure..."
    terraform init
    terraform apply -auto-approve
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