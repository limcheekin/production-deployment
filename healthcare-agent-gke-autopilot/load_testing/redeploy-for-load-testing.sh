#!/bin/bash
# =============================================================================
# Redeploy Parlant for Load Testing
# =============================================================================
# This script reconfigures and redeploys the Parlant application for load 
# testing with a mock LLM server. It switches from Vertex AI to the mock
# service to eliminate external API dependencies during scale testing.
#
# Based on: simulated-scale-implementation-plan.md
#
# What this script does:
# 1. Builds and deploys the mock LLM server
# 2. Updates Parlant deployment to use mock LLM (USE_VERTEX_AI=false)
# 3. Deploys HPA for auto-scaling
# 4. Deploys Locust for load generation
# 5. Validates the entire load testing infrastructure
#
# Prerequisites:
# - GKE cluster is running (setup.sh completed)
# - kubectl configured to the cluster
# - Docker authenticated to Artifact Registry
#
# Usage:
#   ./redeploy-for-load-testing.sh [--skip-build] [--revert]
#
# Options:
#   --skip-build  Skip building and pushing Docker images (use existing)
#   --revert      Revert to production mode (Vertex AI)
# =============================================================================

set -e

# Configuration
PROJECT_ID=$(gcloud config get-value project)
REGION="us-central1"
REPO_NAME="parlant-repo"
NAMESPACE="default"
KSA_NAME="parlant-ksa"
GSA_NAME="parlant-sa"
GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Use timestamp-based image tag to avoid K8s caching issues with "latest"
IMAGE_TAG=$(date +%Y%m%d-%H%M%S)

# Image paths
PARLANT_IMAGE="us-central1-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/parlant-agent:latest"
MOCK_LLM_IMAGE="us-central1-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/mock-llm:$IMAGE_TAG"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }
echo_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Retry helper for flaky commands
retry_command() {
    local max_attempts=${RETRY_ATTEMPTS:-3}
    local delay=${RETRY_DELAY:-5}
    local attempt=1
    local cmd="$@"
    
    while [ $attempt -le $max_attempts ]; do
        echo_info "Attempt $attempt/$max_attempts: $cmd"
        if eval "$cmd"; then
            return 0
        fi
        if [ $attempt -lt $max_attempts ]; then
            echo_warn "Attempt $attempt failed. Retrying in ${delay}s..."
            sleep $delay
        fi
        ((attempt++))
    done
    echo_error "Command failed after $max_attempts attempts: $cmd"
    return 1
}

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Parse arguments
SKIP_BUILD=false
REVERT_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --revert)
            REVERT_MODE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--skip-build] [--revert]"
            exit 1
            ;;
    esac
done

# =============================================================================
# Revert to Production Mode
# =============================================================================
revert_to_production() {
    echo_step "==========================================="
    echo_step "Reverting to Production Mode (Vertex AI)"
    echo_step "==========================================="
    
    # Scale down load testing infrastructure
    echo_info "Scaling down load testing infrastructure..."
    kubectl scale deployment mock-llm --replicas=0 2>/dev/null || true
    kubectl scale deployment locust-master --replicas=0 2>/dev/null || true
    kubectl scale deployment locust-worker --replicas=0 2>/dev/null || true
    
    # Delete HPA if exists
    kubectl delete hpa parlant-hpa 2>/dev/null || true
    
    # Regenerate production deployment manifest
    echo_info "Regenerating production deployment..."
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: parlant
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
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
        image: $PARLANT_IMAGE
        ports:
        - containerPort: 8800
        env:
        # Production: Use Vertex AI
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
            cpu: "2000m"
            memory: "4Gi"
          limits:
            cpu: "2000m"
            memory: "4Gi"
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8800
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3            
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8800
          initialDelaySeconds: 10
EOF
    
    echo_info "Waiting for production rollout..."
    kubectl rollout status deployment/parlant --timeout=300s
    
    echo ""
    echo_info "==========================================="
    echo_info "✅ Reverted to Production Mode"
    echo_info "   Vertex AI: ENABLED"
    echo_info "   Mock LLM:  DISABLED"
    echo_info "==========================================="
}

# =============================================================================
# Build and Push Images
# =============================================================================
build_images() {
    echo_step "==========================================="
    echo_step "Step 1: Building Docker Images"
    echo_step "==========================================="
    
    if [ "$SKIP_BUILD" = true ]; then
        echo_warn "Skipping image build (--skip-build flag set)"
        return
    fi
    
    # Authenticate Docker using gcloud access token (works with sudo docker)
    echo_info "Configuring Docker authentication..."
    gcloud auth print-access-token | sudo docker login -u oauth2accesstoken --password-stdin https://us-central1-docker.pkg.dev
    
    # Build mock LLM image (--no-cache ensures latest code is included)
    echo_info "Building mock LLM server image..."
    sudo docker build --no-cache -t "$MOCK_LLM_IMAGE" \
        -f "$SCRIPT_DIR/Dockerfile" \
        "$SCRIPT_DIR/"
    
    # Push image
    echo_info "Pushing mock LLM image to Artifact Registry..."
    sudo docker push "$MOCK_LLM_IMAGE"
    
    echo_info "Images built and pushed successfully"
}

# =============================================================================
# Deploy Mock LLM Service
# =============================================================================
deploy_mock_llm() {
    echo_step "==========================================="
    echo_step "Step 2: Deploying Mock LLM Service"
    echo_step "==========================================="
    
    # Substitute PROJECT_ID and IMAGE_TAG in the deployment manifest
    echo_info "Applying mock LLM deployment with image tag: $IMAGE_TAG..."
    sed -e "s/PROJECT_ID/$PROJECT_ID/g" \
        -e "s|mock-llm:latest|mock-llm:$IMAGE_TAG|g" \
        "$SCRIPT_DIR/mock-llm-deployment.yaml" | kubectl apply -f -
    
    # Force rollout restart to ensure pods pull the new image
    echo_info "Forcing rollout restart to pull latest image..."
    kubectl rollout restart deployment/mock-llm
    
    # Wait for rollout to complete
    echo_info "Waiting for mock LLM rollout to complete..."
    kubectl rollout status deployment/mock-llm --timeout=180s
    
    # Wait for pods to be ready
    echo_info "Waiting for mock LLM pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=mock-llm --timeout=120s
    
    # Robust health verification loop
    echo_info "Verifying mock LLM health (may take a moment)..."
    local health_ok=false
    for i in {1..10}; do
        # Use kubectl exec to test health from inside the cluster
        if kubectl get pods -l app=mock-llm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | \
           xargs -I {} kubectl exec {} -- curl -sf http://localhost:8000/health 2>/dev/null; then
            echo_info "Mock LLM health check passed"
            health_ok=true
            break
        fi
        echo_warn "Health check attempt $i/10 failed, waiting..."
        sleep 3
    done
    
    if [ "$health_ok" = false ]; then
        echo_warn "Health checks failed but pods are ready - proceeding with caution"
    fi
    
    echo_info "Mock LLM service deployed at: mock-llm.default.svc.cluster.local:8000"
}

# =============================================================================
# Reconfigure Parlant for Load Testing
# =============================================================================
reconfigure_parlant() {
    echo_step "==========================================="
    echo_step "Step 3: Reconfiguring Parlant for Load Testing"
    echo_step "==========================================="
    
    # Clean up old pods first to prevent rollout stalls
    echo_info "Cleaning up any old Parlant pods to prevent rollout issues..."
    kubectl delete pods -l app=parlant --grace-period=10 --force 2>/dev/null || true
    sleep 5
    
    echo_info "Updating Parlant deployment with mock LLM configuration..."
    
    # Generate load testing deployment manifest
    # Key changes:
    # - USE_VERTEX_AI=false
    # - GEMINI_API_KEY=mock-key (required by SDK when not using Vertex AI)
    # - GOOGLE_GEMINI_BASE_URL pointing to mock LLM service
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: parlant
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
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
        image: $PARLANT_IMAGE
        ports:
        - containerPort: 8800
        env:
        # Load Testing Mode: Redirect ALL API calls to mock LLM server
        # The google.genai SDK respects GOOGLE_GEMINI_BASE_URL for the base API URL
        - name: USE_VERTEX_AI
          value: "false"
        - name: GEMINI_API_KEY
          value: "mock-api-key-for-load-testing"
        # This is the key env var - redirects ALL Gemini API calls (including embeddings)
        - name: GOOGLE_GEMINI_BASE_URL
          value: "http://mock-llm.default.svc.cluster.local:8000"
        
        # Keep project info for any other services
        - name: VERTEX_AI_PROJECT_ID
          value: "$PROJECT_ID"
        - name: VERTEX_AI_REGION
          value: "$REGION"
        
        # Sensitive Data from Secrets (unchanged)
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
            cpu: "2000m"
            memory: "4Gi"
          limits:
            cpu: "2000m"
            memory: "4Gi"
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8800
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3            
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8800
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 1
          failureThreshold: 3
        startupProbe:
          httpGet:
            path: /healthz
            port: 8800
          failureThreshold: 30
          periodSeconds: 10
EOF

    echo_info "Waiting for Parlant rollout (timeout: 600s)..."
    if ! kubectl rollout status deployment/parlant --timeout=600s; then
        echo_error "Rollout timed out. Checking pod status..."
        kubectl get pods -l app=parlant -o wide
        echo ""
        echo_error "Pod descriptions:"
        kubectl describe pods -l app=parlant | tail -50
        echo ""
        echo_error "Recent logs:"
        kubectl logs -l app=parlant --tail=30 2>/dev/null || true
        exit 1
    fi
    
    echo_info "Parlant reconfigured for load testing mode"
}

# =============================================================================
# Deploy HPA for Auto-Scaling
# =============================================================================
deploy_hpa() {
    echo_step "==========================================="
    echo_step "Step 4: Deploying Horizontal Pod Autoscaler"
    echo_step "==========================================="
    
    echo_info "Applying HPA configuration..."
    kubectl apply -f "$SCRIPT_DIR/hpa.yaml"
    
    echo_info "HPA deployed (min: 2, max: 3 replicas)"
    kubectl get hpa parlant-hpa
}

# =============================================================================
# Deploy Locust for Load Generation
# =============================================================================
deploy_locust() {
    echo_step "==========================================="
    echo_step "Step 5: Deploying Locust Load Generator"
    echo_step "==========================================="
    
    # Create/update ConfigMap with the load test script
    echo_info "Creating Locust script ConfigMap..."
    kubectl create configmap locust-script \
        --from-file="$SCRIPT_DIR/locust_load_test.py" \
        -o yaml --dry-run=client | kubectl apply -f -
    
    # Deploy Locust
    echo_info "Applying Locust deployment..."
    kubectl apply -f "$SCRIPT_DIR/locust-deployment.yaml"
    
    # Wait for deployment
    echo_info "Waiting for Locust master pod to be ready..."
    kubectl wait --for=condition=ready pod -l app=locust,role=master --timeout=120s
    
    echo_info "Waiting for Locust worker pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=locust,role=worker --timeout=120s
    
    echo_info "Locust deployed successfully"
}

# =============================================================================
# Validate Deployment
# =============================================================================
validate_deployment() {
    echo_step "==========================================="
    echo_step "Step 6: Validating Load Testing Infrastructure"
    echo_step "==========================================="
    
    echo_info "Checking all components..."
    echo ""
    
    # Check Mock LLM
    echo_info "Mock LLM Service:"
    kubectl get pods -l app=mock-llm -o wide
    echo ""
    
    # Check Parlant
    echo_info "Parlant Deployment:"
    kubectl get pods -l app=parlant -o wide
    echo ""
    
    # Check HPA
    echo_info "Horizontal Pod Autoscaler:"
    kubectl get hpa parlant-hpa
    echo ""
    
    # Check Locust
    echo_info "Locust Load Generator:"
    kubectl get pods -l app=locust -o wide
    echo ""
    
    # Get Ingress IP
    INGRESS_IP=$(gcloud compute addresses describe parlant-global-ip --global --format='value(address)' 2>/dev/null || echo "Not found")
    
    echo_info "==========================================="
    echo_info "✅ Load Testing Infrastructure Ready"
    echo_info "==========================================="
    echo ""
    echo_info "Configuration Summary:"
    echo "  • Mode:           LOAD TESTING (Mock LLM)"
    echo "  • Vertex AI:      DISABLED"
    echo "  • Mock LLM:       ENABLED (mock-llm.default.svc.cluster.local:8000)"
    echo "  • HPA:            ENABLED (2-3 replicas)"
    echo ""
    # Get Locust external IP if available
    LOCUST_IP=$(kubectl get svc locust-master -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    echo_info "Endpoints:"
    echo "  • Parlant API:    http://$INGRESS_IP/"
    if [ -n "$LOCUST_IP" ]; then
        echo "  • Locust UI:      http://$LOCUST_IP:8089"
    else
        echo "  • Locust UI:      (pending external IP, use port-forward)"
    fi
    echo ""
    echo_info "To run load tests:"
    echo "  1. Port-forward Locust UI:  kubectl port-forward svc/locust-master 8089:8089"
    echo "  2. Or run from CLI:         ./run-scale-test.sh baseline"
    echo ""
    echo_warn "Remember to revert to production mode after testing:"
    echo "  ./redeploy-for-load-testing.sh --revert"
}

# =============================================================================
# Main Execution
# =============================================================================
main() {
    echo ""
    echo_info "==========================================="
    echo_info "Parlant Load Testing Redeployment Script"
    echo_info "Project: $PROJECT_ID | Region: $REGION"
    echo_info "==========================================="
    echo ""
    
    # Check prerequisites
    if ! command -v kubectl &>/dev/null; then
        echo_error "kubectl not found. Please install kubectl first."
        exit 1
    fi
    
    if ! kubectl cluster-info &>/dev/null; then
        echo_error "Cannot connect to Kubernetes cluster. Run: gcloud container clusters get-credentials parlant-cluster --region=$REGION"
        exit 1
    fi
    
    # Verify parlant-secrets exist
    if ! kubectl get secret parlant-secrets &>/dev/null; then
        echo_error "Secret 'parlant-secrets' not found. Run setup.sh first to create secrets."
        exit 1
    fi
    
    # Handle revert mode
    if [ "$REVERT_MODE" = true ]; then
        revert_to_production
        exit 0
    fi
    
    # Execute deployment steps
    build_images
    deploy_mock_llm
    reconfigure_parlant
    deploy_hpa
    deploy_locust
    validate_deployment
}

main "$@"
