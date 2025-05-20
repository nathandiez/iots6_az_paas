#!/bin/bash
# build_all.sh - A script to deploy Azure resources one step at a time and test data lake ingestion

set -e  # Exit immediately if a command exits with a non-zero status

# Step 1: Deploy the infrastructure
./deploy.sh --infra
# Wait for Azure resources to fully provision
sleep 600  # 10 minutes

# Step 2: Create the Service Principal
./deploy.sh --sp
# Wait for Azure AD permissions to propagate
sleep 300  # 5 minutes

# Step 3: Deploy the Databricks RBAC resources
./deploy.sh --dbrbac
# Wait for RBAC to be fully applied
sleep 300  # 5 minutes

# Step 4: Deploy the API
./deploy.sh --api
# Wait for API to be deployed and started
sleep 120  # 2 minutes

# Step 5: Test the data lake ingestion
./test_datalake.sh


# one line version
# ./deploy.sh --infra && sleep 600 && ./deploy.sh --sp && sleep 300 && ./deploy.sh --dbrbac && sleep 300 && ./deploy.sh --api && sleep 120 && ./test_datalake.sh
