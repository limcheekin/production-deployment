#!/bin/bash

# Define variables
REGION="us-central1"
PROJECT_ID=$(gcloud config get-value project)
SERVICE_ACCOUNT="parlant-sa@${PROJECT_ID}.iam.gserviceaccount.com"
KSA_NAME="parlant-ksa"
OTEL_GSA_NAME="parlant-otel-sa"
OTEL_GSA_EMAIL="${OTEL_GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
NAMESPACE="default"

echo "--- Starting Cleanup for Project: $PROJECT_ID ---"

# 1. Delete Kubernetes Resources (Before Cluster Deletion)
echo "[1/7] Deleting Kubernetes Resources..."

echo "      - Deleting Ingress (Triggers Load Balancer Deletion)..."
kubectl delete ingress parlant-ingress --ignore-not-found=true

echo "      - Deleting ManagedCertificate..."
kubectl delete managedcertificate parlant-cert --ignore-not-found=true

echo "      - Deleting Service..."
kubectl delete service parlant-service --ignore-not-found=true

echo "      - Deleting Deployment..."
kubectl delete deployment parlant --ignore-not-found=true
kubectl delete deployment otel-collector --ignore-not-found=true

echo "      - Deleting BackendConfig..."
kubectl delete backendconfig parlant-backend-config --ignore-not-found=true

echo "      - Deleting Secret..."
kubectl delete secret parlant-secrets --ignore-not-found=true

echo "      - Deleting Kubernetes Service Account..."
kubectl delete serviceaccount $KSA_NAME --ignore-not-found=true

# Wait for LB to release IP locks (Increased to 60s for safety)
echo "      Waiting 60 seconds for LB de-provisioning..."
sleep 60

# 2. Delete GKE Cluster
echo "[2/7] Deleting GKE Autopilot Cluster (parlant-cluster)..."
gcloud container clusters delete parlant-cluster --region $REGION --quiet

# 3. Clean up Networking
echo "[3/7] Cleaning up Networking Resources..."

echo "      - Releasing Static IP..."
gcloud compute addresses delete parlant-global-ip --global --quiet

echo "      - Deleting Cloud NAT & Router..."
gcloud compute routers nats delete parlant-nat --router=parlant-router --region=$REGION --quiet
gcloud compute routers delete parlant-router --region=$REGION --quiet

# 3a. Clean up Forwarding Rules (Release IP usage)
echo "      - Checking for orphaned Forwarding Rules (Global)..."
IP_ADDRESS=$(gcloud compute addresses describe parlant-global-ip --global --format="value(address)" 2>/dev/null)
if [ -n "$IP_ADDRESS" ]; then
    # Find Forwarding Rules using this IP
    FW_RULES=$(gcloud compute forwarding-rules list --filter="IPAddress:$IP_ADDRESS" --format="value(name)" --global 2>/dev/null)
    for RULE in $FW_RULES; do
        echo "      [Cleanup] Deleting Forwarding Rule: $RULE"
        gcloud compute forwarding-rules delete "$RULE" --global --quiet
    done
fi

# 3b. Clean up Network Endpoint Groups (NEGs) - Critical for Subnet Deletion
echo "      - Checking for orphaned Network Endpoint Groups (NEGs)..."
# List NEGs in the VPC (Name and Zone)
gcloud compute network-endpoint-groups list --filter="network:parlant-vpc" --format="value[separator=','](name,zone)" 2>/dev/null | while IFS=, read -r NAME ZONE; do
    if [ -n "$NAME" ]; then
        echo "      [Cleanup] Deleting NEG: $NAME in $ZONE..."
        # Attempt to delete. This might fail if attached to a Backend Service.
        if ! gcloud compute network-endpoint-groups delete "$NAME" --zone="$ZONE" --quiet 2>/dev/null; then
            echo "      [WARN] Could not delete NEG '$NAME'. It might be in use by a Backend Service."
            echo "      [Attempt] Scanning for Backend Services associated with parlant-vpc..."
            
            # Aggressive Strategy: Find Backend Services that use this NEG
            # This is complex to query directly. We will list all BS and grep for the NEG name as a heuristic.
            MATCHING_BS=$(gcloud compute backend-services list --format="value(name)" --filter="backends.group:$NAME" --global 2>/dev/null)
            
            if [ -n "$MATCHING_BS" ]; then
                echo "      [Cleanup] Found Backend Service using NEG: $MATCHING_BS"
                gcloud compute backend-services delete $MATCHING_BS --global --quiet
                
                # Retry NEG deletion
                echo "      [Retry] Deleting NEG: $NAME..."
                gcloud compute network-endpoint-groups delete "$NAME" --zone="$ZONE" --quiet
            else
                echo "      [ERROR] Could not find Backend Service for NEG $NAME. Please check manually."
            fi
        fi
    fi
done

# 4. Clean up Firewall Rules (Critical for VPC Deletion)
echo "[4/7] Cleaning up Residual Firewall Rules..."
# GKE and Ingress often leave rules behind that block VPC deletion. 
# We delete any rule associated with the 'parlant-vpc' network.
FIREWALL_RULES=$(gcloud compute firewall-rules list --filter="network:parlant-vpc" --format="value(name)")
if [ -n "$FIREWALL_RULES" ]; then
    echo "      Deleting rules: $FIREWALL_RULES"
    gcloud compute firewall-rules delete $FIREWALL_RULES --quiet
else
    echo "      No residual firewall rules found."
fi

echo "      - Deleting VPC & Subnet..."
gcloud compute networks subnets delete parlant-subnet --region=$REGION --quiet
gcloud compute networks delete parlant-vpc --quiet

# 5. Clean up IAM & Security
echo "[5/7] Cleaning up IAM & Security..."

echo "      - Cleaning up OTEL Identity..."
# Remove roles from OTEL SA
for ROLE in "roles/cloudtrace.agent" "roles/monitoring.metricWriter" "roles/logging.logWriter"; do
    gcloud projects remove-iam-policy-binding $PROJECT_ID \
        --member "serviceAccount:$OTEL_GSA_EMAIL" \
        --role "$ROLE" --quiet 2>/dev/null || true
done
# Delete OTEL SA
gcloud iam service-accounts delete $OTEL_GSA_EMAIL --quiet || echo "      OTEL SA already deleted or not found."

echo "      - Removing Workload Identity Binding..."
gcloud iam service-accounts remove-iam-policy-binding $SERVICE_ACCOUNT \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA_NAME}]" --quiet 2>/dev/null || echo "      Binding already removed or not found."

echo "      - Removing IAM Policy Binding (Project Level)..."
# Remove the project-level role granted to the service account
gcloud projects remove-iam-policy-binding $PROJECT_ID \
    --member "serviceAccount:$SERVICE_ACCOUNT" \
    --role "roles/aiplatform.user" --quiet 2>/dev/null || echo "      Binding already removed or not found."

echo "      - Deleting Service Account..."
gcloud iam service-accounts delete $SERVICE_ACCOUNT --quiet

echo "      - Deleting Cloud Armor Policy..."
gcloud compute security-policies delete parlant-security-policy --quiet

# 6. Clean up Artifacts
echo "[6/7] Deleting Artifact Registry Repository..."
gcloud artifacts repositories delete parlant-repo --location=$REGION --quiet

# 7. Clean up Local Files
echo "[7/7] Cleaning up Local Generated Files..."
rm -f k8s-manifests.yaml ingress.yaml
echo "      Removed k8s-manifests.yaml and ingress.yaml"

echo "--- Cleanup Complete! ---"
echo "IMPORTANT: Don't forget to terminate your MongoDB Atlas cluster manually via their dashboard."
