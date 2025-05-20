#!/bin/bash
# deploy.sh

set -ex

# Initialize flags
DEPLOY_ALL=true
DEPLOY_API=false
DEPLOY_DBRBAC=false
DEPLOY_INFRA=false
DEPLOY_SP=false  # New flag for Service Principal creation only

# Parse command line arguments
for arg in "$@"; do
    case "$arg" in
        --api)
            DEPLOY_ALL=false
            DEPLOY_API=true
            ;;
        --dbrbac)
            DEPLOY_ALL=false
            DEPLOY_DBRBAC=true
            ;;
        --infra)
            DEPLOY_ALL=false
            DEPLOY_INFRA=true
            ;;
        --sp)
            DEPLOY_ALL=false
            DEPLOY_SP=true
            ;;
        --help)
            echo "Usage: ./deploy.sh [OPTIONS]"
            echo "Options:"
            echo "  --infra      Deploy only the main infrastructure terraform"
            echo "  --api        Deploy only the ingest API service"
            echo "  --sp         Create/update the Databricks Service Principal only"
            echo "  --dbrbac     Deploy only the Databricks RBAC terraform"
            echo "  --help       Show this help message"
            echo ""
            echo "To destroy all resources, use ./destroy_all.sh instead"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check dependencies
command -v az >/dev/null 2>&1 || { echo "Azure CLI not found. Please install it."; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo "Terraform not found. Please install it."; exit 1; }
command -v dotnet >/dev/null 2>&1 || { echo ".NET SDK not found. Please install it."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found. Please install it."; exit 1; }

# Check if logged in to Azure
az account show >/dev/null 2>&1 || {
    echo "Not logged in to Azure. Initiating login..."
    az login
}

# Deploy main infrastructure if needed
cd terraform
if [ "$DEPLOY_ALL" = true ] || [ "$DEPLOY_INFRA" = true ]; then
    echo "Deploying main infrastructure..."
    terraform init
    terraform apply --auto-approve

    # Get outputs for later use
    DATABRICKS_URL=$(terraform output -raw databricks_workspace_url)
    CONFIG_URL=$(terraform output -json config_service_urls | jq -r '."pico_iot_config.json"')
    INGEST_API_URL=$(terraform output -raw ingest_api_url)

    echo "Databricks URL: $DATABRICKS_URL"
else
    # Get the necessary outputs for individual deployments only if not deploying infrastructure
    set +e
    DATABRICKS_URL=$(terraform output -raw databricks_workspace_url 2>/dev/null)
    CONFIG_URL=$(terraform output -json config_service_urls 2>/dev/null | jq -r '."pico_iot_config.json"' 2>/dev/null)
    INGEST_API_URL=$(terraform output -raw ingest_api_url 2>/dev/null)
    set -e
fi
cd ..

# Define the resource group and API name
RESOURCE_GROUP="niotv1-dev-rg"
API_NAME="niotv1-dev-api"

# Create Service Principal if needed
if [ "$DEPLOY_ALL" = true ] || [ "$DEPLOY_SP" = true ]; then
    # derive workspace name from RG
    WORKSPACE_NAME="${RESOURCE_GROUP%-rg}-databricks"
    
    # Only wait if we're doing a full deploy or just deployed the infrastructure
    if [ "$DEPLOY_ALL" = true ] || [ "$DEPLOY_INFRA" = true ]; then
        echo "Waiting for Databricks workspace provisioning to succeed (up to 20 minutes)..."

        MAX_WAIT=1200    # 20 minutes
        ELAPSED=0
        INTERVAL=15     # check every 15s

        while [ $ELAPSED -lt $MAX_WAIT ]; do
            STATE=$(az databricks workspace show \
                      --name "$WORKSPACE_NAME" \
                      --resource-group "$RESOURCE_GROUP" \
                      --query provisioningState -o tsv)

            if [ "$STATE" = "Succeeded" ]; then
                echo "Workspace provisioning is Succeeded after $ELAPSED seconds!"
                break
            fi

            sleep $INTERVAL
            ELAPSED=$((ELAPSED + INTERVAL))
            echo "Still waiting... ($ELAPSED seconds elapsed; current state: $STATE)"
        done

        if [ $ELAPSED -ge $MAX_WAIT ]; then
            echo "Waited $MAX_WAIT seconds and workspace is still not Succeeded (state: $STATE). Proceeding anyway..."
        fi
    fi

    # Create Service Principal for Databricks workspace
    echo "Setting up Service Principal for workspace: $WORKSPACE_NAME in $RESOURCE_GROUP"
    ./create_databricks_sp.sh "$RESOURCE_GROUP" "$WORKSPACE_NAME"
fi

# Deploy Databricks RBAC if needed
if [ "$DEPLOY_ALL" = true ] || [ "$DEPLOY_DBRBAC" = true ]; then
    echo "Deploying Databricks RBAC..."
    
    # Check if terraform.tfvars exists
    if [ ! -f "terraform/databricks-rbac/terraform.tfvars" ]; then
        echo "ERROR: terraform.tfvars not found! Run with --sp first to create Service Principal."
        exit 1
    fi
    
    # Now deploy the RBAC resources
    cd terraform/databricks-rbac
    echo "Using terraform.tfvars for Databricks provider authentication:"
    cat terraform.tfvars
    
    terraform init
    terraform apply --auto-approve
    cd ../..
fi

# Deploy the .NET API if needed
if [ "$DEPLOY_ALL" = true ] || [ "$DEPLOY_API" = true ]; then
    echo "Deploying .NET Ingest API..."

    # Build and deploy API
    cd src/ingest_api
    echo "Building API..."
    dotnet publish -c Release

    echo "Creating deployment zip..."
    cd bin/Release/net8.0/publish
    zip -r ../../../../app.zip .
    cd ../../../..

    echo "Deploying to Azure..."
    az webapp deployment source config-zip \
      --resource-group $RESOURCE_GROUP \
      --name $API_NAME \
      --src app.zip

    cd ../..
fi

# Print summary
echo "Deployment completed successfully!"
echo ""
echo "Application URLs:"
echo "----------------"
[ -n "$CONFIG_URL" ]   && echo "Configuration Service: $CONFIG_URL"
[ -n "$INGEST_API_URL" ] && echo "Ingest API: $INGEST_API_URL"
[ -n "$DATABRICKS_URL" ] && echo "Databricks Workspace: https://$DATABRICKS_URL"