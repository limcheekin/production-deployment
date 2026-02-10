#!/bin/bash
set -e

# ==============================================================================
# GitHub Actions Workload Identity Federation Cleanup Script
# ==============================================================================
# This script removes all resources created by setup-github-wif.sh
#
# Usage:
#   ./clean-up-github-wif.sh
# ==============================================================================

# Variables
PROJECT_ID=$(gcloud config get-value project)
POOL_NAME="github-pool"
PROVIDER_NAME="github-provider"
SA_NAME="github-actions-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "--- Cleaning up GitHub Actions Workload Identity Federation ---"
echo "Project ID: $PROJECT_ID"
echo ""
read -p "Are you sure you want to delete all WIF resources? [y/N]: " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

# ==============================================================================
# Step 1: Remove IAM Bindings from Service Account
# ==============================================================================
echo "[Step 1] Removing IAM bindings from Service Account..."
if gcloud iam service-accounts describe $SA_EMAIL &>/dev/null; then
    # Remove Artifact Registry Writer role
    echo "    - Removing Artifact Registry Writer role..."
    gcloud projects remove-iam-policy-binding $PROJECT_ID \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="roles/artifactregistry.writer" \
        --quiet > /dev/null 2>&1 || echo "      (already removed or not found)"

    # Remove Container Developer role
    echo "    - Removing Container Developer role..."
    gcloud projects remove-iam-policy-binding $PROJECT_ID \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="roles/container.developer" \
        --quiet > /dev/null 2>&1 || echo "      (already removed or not found)"
else
    echo "    - Service account not found, skipping IAM binding removal."
fi

# ==============================================================================
# Step 2: Delete Service Account
# ==============================================================================
echo "[Step 2] Deleting Service Account..."
if gcloud iam service-accounts describe $SA_EMAIL &>/dev/null; then
    gcloud iam service-accounts delete $SA_EMAIL --quiet
    echo "    - Service account deleted."
else
    echo "    - Service account '$SA_NAME' not found, skipping."
fi

# ==============================================================================
# Step 3: Delete OIDC Provider
# ==============================================================================
echo "[Step 3] Deleting OIDC Provider..."
if gcloud iam workload-identity-pools providers describe $PROVIDER_NAME \
    --location="global" \
    --workload-identity-pool=$POOL_NAME &>/dev/null; then
    gcloud iam workload-identity-pools providers delete $PROVIDER_NAME \
        --location="global" \
        --workload-identity-pool=$POOL_NAME \
        --quiet
    echo "    - Provider deleted."
else
    echo "    - Provider '$PROVIDER_NAME' not found, skipping."
fi

# ==============================================================================
# Step 4: Delete Workload Identity Pool
# ==============================================================================
echo "[Step 4] Deleting Workload Identity Pool..."
if gcloud iam workload-identity-pools describe $POOL_NAME --location="global" &>/dev/null; then
    gcloud iam workload-identity-pools delete $POOL_NAME \
        --location="global" \
        --quiet
    echo "    - Pool deleted."
else
    echo "    - Pool '$POOL_NAME' not found, skipping."
fi

echo ""
echo "=============================================================================="
echo "Cleanup Complete!"
echo "=============================================================================="
echo ""
echo "Remember to also remove these secrets from GitHub:"
echo "  - GCP_PROJECT_ID"
echo "  - GCP_SERVICE_ACCOUNT"
echo "  - GCP_WORKLOAD_IDENTITY_PROVIDER"
echo ""
