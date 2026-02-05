#!/bin/bash
set -e

# ==============================================================================
# Parlant GCP Setup Script (Automates Steps 2, 3, and 4)
# ==============================================================================

# Variables
PROJECT_ID=$(gcloud config get-value project)
REGION="us-central1"
CLUSTER_NAME="parlant-cluster"
NETWORK_NAME="parlant-vpc"
SUBNET_NAME="parlant-subnet"
ROUTER_NAME="parlant-router"
NAT_NAME="parlant-nat"
GSA_NAME="parlant-sa"
GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
KSA_NAME="parlant-ksa"
NAMESPACE="default"
REPO_NAME="parlant-repo"
IMAGE_NAME="parlant-agent"

echo "--- Starting Parlant Setup for Project: $PROJECT_ID in $REGION ---"

# ==============================================================================
# Pre-flight Check: Docker Image
# ==============================================================================
echo "[Pre-flight] Checking Docker Image..."
IMAGE_PATH="us-central1-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/$IMAGE_NAME:latest"

if gcloud artifacts docker images describe $IMAGE_PATH &>/dev/null; then
    echo "    - Image found: $IMAGE_PATH"
else
    echo "    [WARNING] Image not found at: $IMAGE_PATH"
    echo "    The deployment will fail with ImagePullBackOff until you build and push the image."
    echo "    Make sure to run 'Step 2' from the guide (Build & Push) before or after this script."
    echo "    Continuing setup..."
    sleep 3
fi

# ==============================================================================
# Step 2: Infrastructure (GKE Autopilot)
# ==============================================================================
echo "[Step 2] Setting up Infrastructure..."

# 1. Create VPC and Subnet
if gcloud compute networks describe $NETWORK_NAME &>/dev/null; then
    echo "    - Network $NETWORK_NAME already exists, skipping creation."
else
    echo "    - Creating VPC $NETWORK_NAME..."
    gcloud compute networks create $NETWORK_NAME --subnet-mode=custom --quiet
    gcloud compute networks subnets create $SUBNET_NAME \
        --network=$NETWORK_NAME \
        --region=$REGION \
        --range=10.0.0.0/20 --quiet
fi

# 2. Create Cloud NAT (Critical for Autopilot Private Nodes)
if gcloud compute routers describe $ROUTER_NAME --region=$REGION &>/dev/null; then
    echo "    - Cloud Router/NAT already exists, skipping creation."
else
    echo "    - Creating Cloud Router and NAT..."
    gcloud compute routers create $ROUTER_NAME --network=$NETWORK_NAME --region=$REGION --quiet
    gcloud compute routers nats create $NAT_NAME \
        --router=$ROUTER_NAME \
        --region=$REGION \
        --auto-allocate-nat-external-ips \
        --nat-all-subnet-ip-ranges --quiet
fi

# 3. Create GKE Autopilot Cluster
if gcloud container clusters describe $CLUSTER_NAME --region=$REGION &>/dev/null; then
    echo "    - Cluster $CLUSTER_NAME already exists, checking status..."
else
    echo "    - Creating GKE Autopilot Cluster (This may take 10-15 minutes)..."
    gcloud container clusters create-auto $CLUSTER_NAME \
        --region=$REGION \
        --network=$NETWORK_NAME \
        --subnetwork=$SUBNET_NAME \
        --quiet
fi

# Get Credentials
echo "    - Fetching cluster credentials..."
gcloud container clusters get-credentials $CLUSTER_NAME --region=$REGION --quiet

# ==============================================================================
# Step 3: Security Layer (Cloud Armor)
# ==============================================================================
echo "[Step 3] Setting up Cloud Armor..."

POLICY_NAME="parlant-security-policy"
if gcloud compute security-policies describe $POLICY_NAME &>/dev/null; then
    echo "    - Security policy $POLICY_NAME already exists, skipping."
else
    echo "    - Creating Security Policy $POLICY_NAME..."
    gcloud compute security-policies create $POLICY_NAME \
        --description "Policy for Parlant Agent" --quiet
    
    # Rule 1: XSS Protection
    gcloud compute security-policies rules create 1000 \
        --security-policy $POLICY_NAME \
        --expression "evaluatePreconfiguredExpr('xss-stable')" \
        --action "deny-403" \
        --description "Block XSS attacks" --quiet

    # Rule 2: Rate Limiting
    gcloud compute security-policies rules create 3000 \
        --security-policy $POLICY_NAME \
        --src-ip-ranges "*" \
        --action "throttle" \
        --rate-limit-threshold-count 100 \
        --rate-limit-threshold-interval-sec 60 \
        --conform-action "allow" \
        --exceed-action "deny-429" \
        --enforce-on-key "IP" --quiet
fi

# ==============================================================================
# Step 4: Secure Deployment
# ==============================================================================
echo "[Step 4] Configuring Secure Deployment..."

# 4.1 Workload Identity Setup
echo "    - Configuring Workload Identity..."
if ! gcloud iam service-accounts describe $GSA_EMAIL &>/dev/null; then
    gcloud iam service-accounts create $GSA_NAME --display-name "Parlant Agent Service Account" --quiet
fi

# Grant Vertex AI User Role
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member "serviceAccount:$GSA_EMAIL" \
    --role "roles/aiplatform.user" --quiet > /dev/null

# Bind KSA to GSA
gcloud iam service-accounts add-iam-policy-binding $GSA_EMAIL \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA_NAME}]" --quiet > /dev/null

# 4.2 Secrets Management
echo "    - Configuring Secrets..."
if kubectl get secret parlant-secrets &>/dev/null; then
    echo "      Secret 'parlant-secrets' already exists."
else
    echo "      Please enter your Configuration Secrets in .env file:"
    echo "      mongodb-sessions-uri=mongodb+srv://user:pass@host/db..."
    echo "      mongodb-customers-uri=mongodb+srv://user:pass@host/db..."
    echo "      jwt-secret-key=super-secret-key"
    
    kubectl create secret generic parlant-secrets --from-env-file=.env
    echo "      Secret created."
fi

# 4.3 Manifest Generation & Application
echo "    - Generating Kubernetes Manifests..."

# Generate k8s-manifests.yaml
cat <<EOF > k8s-manifests.yaml
# BackendConfig
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: parlant-backend-config
spec:
  securityPolicy:
    name: "parlant-security-policy"
  timeoutSec: 120
  healthCheck:
    checkIntervalSec: 10
    timeoutSec: 5
    type: HTTP
    requestPath: /health
    port: 8800
---
# Service
apiVersion: v1
kind: Service
metadata:
  name: parlant-service
  annotations:
    cloud.google.com/backend-config: '{"default": "parlant-backend-config"}'
    cloud.google.com/neg: '{"ingress": true}'
spec:
  type: ClusterIP
  selector:
    app: parlant
  ports:
  - port: 8800
    targetPort: 8800
    name: http
---
# Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: parlant
spec:
  replicas: 2
  selector:
    matchLabels:
      app: parlant
  template:
    metadata:
      labels:
        app: parlant
    spec:
      serviceAccountName: $KSA_NAME
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
      containers:
      - name: parlant
        image: $IMAGE_PATH
        ports:
        - containerPort: 8800
        env:
        # Vertex AI Config
        - name: USE_VERTEX_AI
          value: "true"
        - name: VERTEX_AI_PROJECT_ID
          value: "$PROJECT_ID"
        - name: VERTEX_AI_REGION
          value: "$REGION"
        - name: VERTEX_AI_MODEL
          value: "gemini-2.5-flash"
        
        # Sensitive Data from Secrets
        - name: MONGODB_SESSIONS_URI
          valueFrom:
            secretKeyRef:
              name: parlant-secrets
              key: mongodb-sessions-uri
        - name: MONGODB_CUSTOMERS_URI
          valueFrom:
            secretKeyRef:
              name: parlant-secrets
              key: mongodb-customers-uri
        - name: JWT_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: parlant-secrets
              key: jwt-secret-key
        resources:
          requests:
            cpu: "500m"
            memory: "1Gi"
          limits:
            cpu: "1000m"
            memory: "2Gi"
        livenessProbe:
          httpGet:
            path: /health
            port: 8800
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3            
        readinessProbe:
          httpGet:
            path: /health
            port: 8800
          initialDelaySeconds: 10
---
# Service Account
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $KSA_NAME
  annotations:
    iam.gke.io/gcp-service-account: $GSA_EMAIL
EOF

echo "    - Applying Core Manifests..."
kubectl apply -f k8s-manifests.yaml

# 4.4 Ingress Configuration (Option A vs B)
echo "[Ingress Configuration]"
echo "    - Reserving Global Static IP..."
if gcloud compute addresses describe parlant-global-ip --global &>/dev/null; then
    echo "      IP 'parlant-global-ip' already reserved."
else
    gcloud compute addresses create parlant-global-ip --global --quiet
fi

echo ""
echo "Select Ingress Option:"
echo "  [A] Production (HTTPS + Domain Name)"
echo "  [B] Testing (HTTP Only / IP Address)"
read -p "Enter choice [A/B]: " INGRESS_CHOICE

if [[ "$INGRESS_CHOICE" == "A" || "$INGRESS_CHOICE" == "a" ]]; then
    read -p "Enter your domain name (e.g., api.example.com): " DOMAIN_NAME
    
    cat <<EOF > ingress.yaml
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata:
  name: parlant-cert
spec:
  domains:
    - $DOMAIN_NAME
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: parlant-ingress
  annotations:
    kubernetes.io/ingress.global-static-ip-name: "parlant-global-ip"
    networking.gke.io/managed-certificates: "parlant-cert"
    kubernetes.io/ingress.allow-http: "false"
spec:
  ingressClassName: "gce"
  rules:
  - host: $DOMAIN_NAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: parlant-service
            port:
              number: 8800
EOF
    echo "    - Applying HTTPS Ingress for $DOMAIN_NAME..."

else
    cat <<EOF > ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: parlant-ingress
  annotations:
    kubernetes.io/ingress.global-static-ip-name: "parlant-global-ip"
spec:
  ingressClassName: "gce"
  defaultBackend:
    service:
      name: parlant-service
      port:
        number: 8800
EOF
    echo "    - Applying HTTP Ingress (Testing Mode)..."
fi

kubectl apply -f ingress.yaml

echo ""
echo "--- Setup Complete! ---"
echo "Public IP Address:"
gcloud compute addresses describe parlant-global-ip --global --format='value(address)'
echo "Note: It may take 10-15 minutes for the Load Balancer to provision."
if [[ "$INGRESS_CHOICE" == "A" || "$INGRESS_CHOICE" == "a" ]]; then
    echo "IMPORTANT: Update your DNS A Record for $DOMAIN_NAME to point to the IP above."
fi