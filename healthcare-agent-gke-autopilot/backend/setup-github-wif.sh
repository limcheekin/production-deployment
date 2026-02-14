#!/bin/bash
set -e

# ==============================================================================
# GitHub Actions Workload Identity Federation Setup Script
# ==============================================================================
# This script sets up Workload Identity Federation to allow GitHub Actions
# to authenticate to GCP without service account keys.
#
# Prerequisites:
#   - gcloud CLI installed and authenticated
#   - GCP project configured (gcloud config set project YOUR_PROJECT)
#   - IAM Credentials API enabled
#
# Usage:
#   ./setup-github-wif.sh YOUR_GITHUB_ORG/YOUR_REPO_NAME
#
# Example:
#   ./setup-github-wif.sh mycompany/healthcare-agent-gke-autopilot
# ==============================================================================

# Check for required argument
if [ -z "$1" ]; then
    echo "Error: GitHub repository name is required."
    echo "Usage: $0 GITHUB_ORG/REPO_NAME"
    echo "Example: $0 mycompany/healthcare-agent-gke-autopilot"
    exit 1
fi

GITHUB_REPO="$1"

# Variables
PROJECT_ID=$(gcloud config get-value project)
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')
POOL_NAME="github-pool"
PROVIDER_NAME="github-provider"
SA_NAME="github-actions-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "--- Setting up GitHub Actions Workload Identity Federation ---"
echo "Project ID:     $PROJECT_ID"
echo "Project Number: $PROJECT_NUMBER"
echo "GitHub Repo:    $GITHUB_REPO"
echo ""

# ==============================================================================
# Step 1: Enable Required APIs
# ==============================================================================
echo "[Step 1] Enabling required APIs..."
gcloud services enable iamcredentials.googleapis.com --quiet
gcloud services enable iam.googleapis.com --quiet

# ==============================================================================
# Step 2: Create Workload Identity Pool
# ==============================================================================
echo "[Step 2] Creating Workload Identity Pool..."
if gcloud iam workload-identity-pools describe $POOL_NAME --location="global" &>/dev/null; then
    echo "    - Pool '$POOL_NAME' already exists, skipping."
else
    gcloud iam workload-identity-pools create $POOL_NAME \
        --location="global" \
        --display-name="GitHub Actions Pool" \
        --description="Workload Identity Pool for GitHub Actions" \
        --quiet
    echo "    - Pool created."
fi

# ==============================================================================
# Step 3: Create OIDC Provider
# ==============================================================================
echo "[Step 3] Creating OIDC Provider..."
if gcloud iam workload-identity-pools providers describe $PROVIDER_NAME \
    --location="global" \
    --workload-identity-pool=$POOL_NAME &>/dev/null; then
    echo "    - Provider '$PROVIDER_NAME' already exists, skipping."
else
    gcloud iam workload-identity-pools providers create-oidc $PROVIDER_NAME \
        --location="global" \
        --workload-identity-pool=$POOL_NAME \
        --display-name="GitHub Provider" \
        --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
        --attribute-condition="assertion.repository=='${GITHUB_REPO}'" \
        --issuer-uri="https://token.actions.githubusercontent.com" \
        --quiet
    echo "    - Provider created."
fi

# ==============================================================================
# Step 4: Create Service Account
# ==============================================================================
echo "[Step 4] Creating Service Account..."
if gcloud iam service-accounts describe $SA_EMAIL &>/dev/null; then
    echo "    - Service account '$SA_NAME' already exists, skipping."
else
    gcloud iam service-accounts create $SA_NAME \
        --display-name="GitHub Actions Service Account" \
        --description="SA for GitHub Actions CI/CD pipeline" \
        --quiet
    echo "    - Service account created."
    echo "    - Waiting for propagation..."
    sleep 10
fi

# ==============================================================================
# Step 5: Grant IAM Roles to Service Account
# ==============================================================================
echo "[Step 5] Granting IAM roles..."

# Artifact Registry Writer - to push Docker images
echo "    - Granting Artifact Registry Writer..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/artifactregistry.writer" \
    --quiet > /dev/null

# Container Developer - to manage GKE deployments
echo "    - Granting Container Developer..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/container.developer" \
    --quiet > /dev/null

echo "    - Roles granted."

# ==============================================================================
# Step 6: Allow GitHub to Impersonate Service Account
# ==============================================================================
echo "[Step 6] Configuring Workload Identity binding..."
gcloud iam service-accounts add-iam-policy-binding $SA_EMAIL \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/attribute.repository/${GITHUB_REPO}" \
    --quiet > /dev/null
echo "    - Binding configured for repository: $GITHUB_REPO"

# ==============================================================================
# Output: GitHub Secrets Configuration
# ==============================================================================
WIF_PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/providers/${PROVIDER_NAME}"

echo ""
echo "=============================================================================="
echo "Setup Complete! Configure these GitHub Secrets:"
echo "=============================================================================="
echo ""
echo "Go to: https://github.com/${GITHUB_REPO}/settings/secrets/actions"
echo ""
echo "Add the following secrets:"
echo ""
echo "┌─────────────────────────────────┬───────────────────────────────────────────┐"
echo "│ Secret Name                     │ Value                                     │"
echo "├─────────────────────────────────┼───────────────────────────────────────────┤"
printf "│ %-31s │ %-41s │\n" "GCP_PROJECT_ID" "$PROJECT_ID"
printf "│ %-31s │ %-41s │\n" "GCP_SERVICE_ACCOUNT" "$SA_EMAIL"
echo "├─────────────────────────────────┼───────────────────────────────────────────┤"
echo "│ GCP_WORKLOAD_IDENTITY_PROVIDER  │ (see below - too long for table)          │"
echo "└─────────────────────────────────┴───────────────────────────────────────────┘"
echo ""
echo "GCP_WORKLOAD_IDENTITY_PROVIDER value:"
echo "$WIF_PROVIDER"
echo ""
echo "=============================================================================="
