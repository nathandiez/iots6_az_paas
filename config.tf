# config.tf - Edit this file to customize your deployment

# User settings - Change these for your personal deployment
locals {
  # The person deploying this project
  owner_email = "nathandiez12@gmail.com"
  
  # Unique suffix to ensure your resources don't conflict with others
  # Change this to your name or other identifier (e.g., "-john", "-test2")
  name_suffix = ""  # For the original deployment, leave empty
  
  # Project identification
  project_name = "niotv1"
  environment = "dev"
  
  # Azure region
  location = "East US 2"  # Close to Georgia
  
  # Storage account prefix (3-8 characters, lowercase letters and numbers only)
  storage_name_prefix = "raraid3"
}