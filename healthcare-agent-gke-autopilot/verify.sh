#!/bin/bash
# ==============================================================================
# Parlant GCP Deployment Verification Script
# ==============================================================================
# This script verifies that all resources created by setup.sh are deployed
# successfully. It checks each component and provides a summary report.
# ==============================================================================

# Note: We intentionally do NOT use set -e here because we want to continue
# checking all resources even if some checks fail.

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Variables (match setup.sh)
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
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
POLICY_NAME="parlant-security-policy"

# Counters for summary
PASSED=0
FAILED=0
WARNINGS=0

# ==============================================================================
# Helper Functions
# ==============================================================================

check_pass() {
    echo -e "    ${GREEN}✓${NC} $1"
    ((PASSED++)) || true
}

check_fail() {
    echo -e "    ${RED}✗${NC} $1"
    ((FAILED++)) || true
}

check_warn() {
    echo -e "    ${YELLOW}⚠${NC} $1"
    ((WARNINGS++)) || true
}

check_info() {
    echo -e "    ${BLUE}ℹ${NC} $1"
}

section_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}[$1]${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ==============================================================================
# Start Verification
# ==============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║           Parlant GCP Deployment Verification Script                          ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Project ID: $PROJECT_ID"
echo "Region: $REGION"
echo "Timestamp: $(date)"

# ==============================================================================
# 1. Verify Docker Image in Artifact Registry
# ==============================================================================
section_header "Docker Image (Artifact Registry)"

IMAGE_PATH="us-central1-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/$IMAGE_NAME:latest"

# Check Artifact Registry repository
if gcloud artifacts repositories describe $REPO_NAME --location=$REGION &>/dev/null; then
    check_pass "Artifact Registry repository '$REPO_NAME' exists"
    
    # Check if image exists
    if gcloud artifacts docker images describe $IMAGE_PATH &>/dev/null; then
        check_pass "Docker image exists: $IMAGE_NAME:latest"
        
        # Get image details
        IMAGE_DIGEST=$(gcloud artifacts docker images describe $IMAGE_PATH --format='value(image_summary.digest)' 2>/dev/null || echo "N/A")
        check_info "Image digest: $IMAGE_DIGEST"
    else
        check_fail "Docker image NOT found: $IMAGE_PATH"
    fi
else
    check_fail "Artifact Registry repository '$REPO_NAME' does NOT exist"
fi

# ==============================================================================
# 2. Verify VPC Network
# ==============================================================================
section_header "VPC Network"

if gcloud compute networks describe $NETWORK_NAME &>/dev/null; then
    check_pass "VPC network '$NETWORK_NAME' exists"
else
    check_fail "VPC network '$NETWORK_NAME' does NOT exist"
fi

# Check Subnet
if gcloud compute networks subnets describe $SUBNET_NAME --region=$REGION &>/dev/null; then
    check_pass "Subnet '$SUBNET_NAME' exists"
    
    # Get subnet CIDR
    SUBNET_CIDR=$(gcloud compute networks subnets describe $SUBNET_NAME --region=$REGION --format='value(ipCidrRange)' 2>/dev/null)
    check_info "Subnet CIDR: $SUBNET_CIDR"
else
    check_fail "Subnet '$SUBNET_NAME' does NOT exist"
fi

# ==============================================================================
# 3. Verify Cloud Router and NAT
# ==============================================================================
section_header "Cloud Router and NAT"

if gcloud compute routers describe $ROUTER_NAME --region=$REGION &>/dev/null; then
    check_pass "Cloud Router '$ROUTER_NAME' exists"
else
    check_fail "Cloud Router '$ROUTER_NAME' does NOT exist"
fi

# Check NAT configuration
NAT_STATUS=$(gcloud compute routers nats describe $NAT_NAME --router=$ROUTER_NAME --region=$REGION --format='value(name)' 2>/dev/null || echo "")
if [[ -n "$NAT_STATUS" ]]; then
    check_pass "Cloud NAT '$NAT_NAME' exists"
else
    check_fail "Cloud NAT '$NAT_NAME' does NOT exist"
fi

# ==============================================================================
# 4. Verify GKE Autopilot Cluster
# ==============================================================================
section_header "GKE Autopilot Cluster"

if gcloud container clusters describe $CLUSTER_NAME --region=$REGION &>/dev/null; then
    check_pass "GKE cluster '$CLUSTER_NAME' exists"
    
    # Get cluster status
    CLUSTER_STATUS=$(gcloud container clusters describe $CLUSTER_NAME --region=$REGION --format='value(status)' 2>/dev/null)
    if [[ "$CLUSTER_STATUS" == "RUNNING" ]]; then
        check_pass "Cluster status: RUNNING"
    else
        check_warn "Cluster status: $CLUSTER_STATUS (expected: RUNNING)"
    fi
    
    # Verify it's Autopilot
    AUTOPILOT=$(gcloud container clusters describe $CLUSTER_NAME --region=$REGION --format='value(autopilot.enabled)' 2>/dev/null)
    if [[ "$AUTOPILOT" == "True" ]]; then
        check_pass "Cluster mode: Autopilot"
    else
        check_warn "Cluster is NOT in Autopilot mode"
    fi
    
    # Get cluster credentials for kubectl commands
    echo "    - Fetching cluster credentials..."
    gcloud container clusters get-credentials $CLUSTER_NAME --region=$REGION --quiet 2>/dev/null
else
    check_fail "GKE cluster '$CLUSTER_NAME' does NOT exist"
    echo -e "    ${RED}Cannot proceed with Kubernetes resource verification without cluster${NC}"
fi

# ==============================================================================
# 5. Verify Cloud Armor Security Policy
# ==============================================================================
section_header "Cloud Armor Security Policy"

if gcloud compute security-policies describe $POLICY_NAME &>/dev/null; then
    check_pass "Security policy '$POLICY_NAME' exists"
    
    # Check for XSS rule (priority 1000)
    XSS_RULE=$(gcloud compute security-policies rules describe 1000 --security-policy=$POLICY_NAME --format='value(action)' 2>/dev/null || echo "")
    if [[ "$XSS_RULE" == "deny(403)" ]]; then
        check_pass "XSS protection rule (1000) configured"
    else
        check_warn "XSS protection rule (1000) may not be configured correctly"
    fi
    
    # Check for Rate Limiting rule (priority 3000)
    RATE_RULE=$(gcloud compute security-policies rules describe 3000 --security-policy=$POLICY_NAME --format='value(action)' 2>/dev/null || echo "")
    if [[ "$RATE_RULE" == "throttle" ]]; then
        check_pass "Rate limiting rule (3000) configured"
    else
        check_warn "Rate limiting rule (3000) may not be configured correctly"
    fi
else
    check_fail "Security policy '$POLICY_NAME' does NOT exist"
fi

# ==============================================================================
# 6. Verify GCP Service Account
# ==============================================================================
section_header "GCP Service Account (Workload Identity)"

if gcloud iam service-accounts describe $GSA_EMAIL &>/dev/null; then
    check_pass "GCP Service Account '$GSA_NAME' exists"
    
    # Check Vertex AI role binding
    VERTEX_ROLE=$(gcloud projects get-iam-policy $PROJECT_ID --flatten="bindings[].members" --format="value(bindings.role)" --filter="bindings.members:serviceAccount:$GSA_EMAIL AND bindings.role:roles/aiplatform.user" 2>/dev/null || echo "")
    if [[ -n "$VERTEX_ROLE" ]]; then
        check_pass "Vertex AI User role assigned"
    else
        check_warn "Vertex AI User role may not be assigned"
    fi
    
    # Check Workload Identity binding
    WI_BINDING=$(gcloud iam service-accounts get-iam-policy $GSA_EMAIL --format="value(bindings.members)" 2>/dev/null | grep -o "serviceAccount:${PROJECT_ID}.svc.id.goog\[${NAMESPACE}/${KSA_NAME}\]" || echo "")
    if [[ -n "$WI_BINDING" ]]; then
        check_pass "Workload Identity binding configured"
    else
        check_warn "Workload Identity binding may not be configured"
    fi
else
    check_fail "GCP Service Account '$GSA_NAME' does NOT exist"
fi

# ==============================================================================
# 7. Verify Global Static IP
# ==============================================================================
section_header "Global Static IP"

if gcloud compute addresses describe parlant-global-ip --global &>/dev/null; then
    check_pass "Global static IP 'parlant-global-ip' exists"
    
    IP_ADDRESS=$(gcloud compute addresses describe parlant-global-ip --global --format='value(address)' 2>/dev/null)
    check_info "IP Address: $IP_ADDRESS"
    
    IP_STATUS=$(gcloud compute addresses describe parlant-global-ip --global --format='value(status)' 2>/dev/null)
    check_info "IP Status: $IP_STATUS"
else
    check_fail "Global static IP 'parlant-global-ip' does NOT exist"
fi

# ==============================================================================
# 8. Verify Kubernetes Resources
# ==============================================================================
section_header "Kubernetes Resources"

# Check if kubectl is configured
if ! kubectl cluster-info &>/dev/null; then
    check_fail "Cannot connect to Kubernetes cluster"
    echo -e "    ${RED}Skipping Kubernetes resource verification${NC}"
else
    check_pass "Connected to Kubernetes cluster"
    
    # 8.1 Verify Kubernetes Secret
    echo ""
    echo "  [Secrets]"
    if kubectl get secret parlant-secrets -n $NAMESPACE &>/dev/null; then
        check_pass "Secret 'parlant-secrets' exists"
        
        # Check required keys
        for KEY in "mongodb-sessions-uri" "mongodb-customers-uri" "jwt-secret-key"; do
            if kubectl get secret parlant-secrets -n $NAMESPACE -o jsonpath="{.data.$KEY}" 2>/dev/null | grep -q .; then
                check_pass "Secret key '$KEY' exists"
            else
                check_warn "Secret key '$KEY' may be missing"
            fi
        done
    else
        check_fail "Secret 'parlant-secrets' does NOT exist"
    fi
    
    # 8.2 Verify Kubernetes Service Account
    echo ""
    echo "  [Service Account]"
    if kubectl get serviceaccount $KSA_NAME -n $NAMESPACE &>/dev/null; then
        check_pass "Kubernetes ServiceAccount '$KSA_NAME' exists"
        
        # Check GCP annotation
        KSA_ANNOTATION=$(kubectl get serviceaccount $KSA_NAME -n $NAMESPACE -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}' 2>/dev/null)
        if [[ "$KSA_ANNOTATION" == "$GSA_EMAIL" ]]; then
            check_pass "ServiceAccount annotated with GCP SA"
        else
            check_warn "ServiceAccount GCP annotation may be incorrect"
        fi
    else
        check_fail "Kubernetes ServiceAccount '$KSA_NAME' does NOT exist"
    fi
    
    # 8.3 Verify BackendConfig
    echo ""
    echo "  [BackendConfig]"
    if kubectl get backendconfig parlant-backend-config -n $NAMESPACE &>/dev/null; then
        check_pass "BackendConfig 'parlant-backend-config' exists"
        
        # Check security policy reference
        BC_POLICY=$(kubectl get backendconfig parlant-backend-config -n $NAMESPACE -o jsonpath='{.spec.securityPolicy.name}' 2>/dev/null)
        if [[ "$BC_POLICY" == "$POLICY_NAME" ]]; then
            check_pass "BackendConfig references security policy"
        else
            check_warn "BackendConfig security policy reference may be incorrect"
        fi
    else
        check_fail "BackendConfig 'parlant-backend-config' does NOT exist"
    fi
    
    # 8.4 Verify Service
    echo ""
    echo "  [Service]"
    if kubectl get service parlant-service -n $NAMESPACE &>/dev/null; then
        check_pass "Service 'parlant-service' exists"
        
        SVC_TYPE=$(kubectl get service parlant-service -n $NAMESPACE -o jsonpath='{.spec.type}' 2>/dev/null)
        check_info "Service type: $SVC_TYPE"
        
        SVC_PORT=$(kubectl get service parlant-service -n $NAMESPACE -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
        check_info "Service port: $SVC_PORT"
    else
        check_fail "Service 'parlant-service' does NOT exist"
    fi
    
    # 8.5 Verify Deployment
    echo ""
    echo "  [Deployment]"
    if kubectl get deployment parlant -n $NAMESPACE &>/dev/null; then
        check_pass "Deployment 'parlant' exists"
        
        # Check replicas
        DESIRED=$(kubectl get deployment parlant -n $NAMESPACE -o jsonpath='{.spec.replicas}' 2>/dev/null)
        READY=$(kubectl get deployment parlant -n $NAMESPACE -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        READY=${READY:-0}
        
        if [[ "$READY" -eq "$DESIRED" ]] && [[ "$READY" -gt 0 ]]; then
            check_pass "All replicas ready: $READY/$DESIRED"
        elif [[ "$READY" -gt 0 ]]; then
            check_warn "Partial replicas ready: $READY/$DESIRED"
        else
            check_fail "No replicas ready: $READY/$DESIRED"
        fi
        
        # Check deployment conditions
        AVAILABLE=$(kubectl get deployment parlant -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
        if [[ "$AVAILABLE" == "True" ]]; then
            check_pass "Deployment is Available"
        else
            check_warn "Deployment is NOT Available"
        fi
        
        # Check image
        DEPLOYED_IMAGE=$(kubectl get deployment parlant -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
        check_info "Deployed image: $DEPLOYED_IMAGE"
    else
        check_fail "Deployment 'parlant' does NOT exist"
    fi
    
    # 8.6 Verify Pods
    echo ""
    echo "  [Pods]"
    POD_COUNT=$(kubectl get pods -n $NAMESPACE -l app=parlant --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$POD_COUNT" -gt 0 ]]; then
        check_pass "Found $POD_COUNT pod(s) with label app=parlant"
        
        # Check pod status
        RUNNING_PODS=$(kubectl get pods -n $NAMESPACE -l app=parlant --no-headers 2>/dev/null | grep -c "Running" || true)
        RUNNING_PODS=${RUNNING_PODS:-0}
        if [[ "$RUNNING_PODS" -eq "$POD_COUNT" ]] && [[ "$RUNNING_PODS" -gt 0 ]]; then
            check_pass "All pods are Running"
        else
            check_warn "Only $RUNNING_PODS/$POD_COUNT pods are Running"
            
            # Show pod statuses
            echo "    Pod Status Details:"
            kubectl get pods -n $NAMESPACE -l app=parlant --no-headers 2>/dev/null | while read line; do
                POD_NAME=$(echo $line | awk '{print $1}')
                POD_STATUS=$(echo $line | awk '{print $3}')
                echo "      - $POD_NAME: $POD_STATUS"
            done
        fi
        
        # Check for ImagePullBackOff or other issues
        PROBLEM_PODS=$(kubectl get pods -n $NAMESPACE -l app=parlant --no-headers 2>/dev/null | grep -E "(ImagePullBackOff|ErrImagePull|CrashLoopBackOff|Error)" || echo "")
        if [[ -n "$PROBLEM_PODS" ]]; then
            check_fail "Some pods have issues (ImagePullBackOff/CrashLoopBackOff)"
        fi
    else
        check_fail "No pods found with label app=parlant"
    fi
    
    # 8.7 Verify Ingress
    echo ""
    echo "  [Ingress]"
    if kubectl get ingress parlant-ingress -n $NAMESPACE &>/dev/null; then
        check_pass "Ingress 'parlant-ingress' exists"
        
        # Check ingress class
        INGRESS_CLASS=$(kubectl get ingress parlant-ingress -n $NAMESPACE -o jsonpath='{.spec.ingressClassName}' 2>/dev/null)
        check_info "Ingress class: $INGRESS_CLASS"
        
        # Check ingress IP
        INGRESS_IP=$(kubectl get ingress parlant-ingress -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        if [[ -n "$INGRESS_IP" ]]; then
            check_pass "Ingress has IP assigned: $INGRESS_IP"
        else
            check_warn "Ingress IP not yet assigned (may take 10-15 min)"
        fi
        
        # Check for managed certificate (if HTTPS)
        if kubectl get managedcertificate parlant-cert -n $NAMESPACE &>/dev/null; then
            check_pass "ManagedCertificate 'parlant-cert' exists"
            
            CERT_STATUS=$(kubectl get managedcertificate parlant-cert -n $NAMESPACE -o jsonpath='{.status.certificateStatus}' 2>/dev/null)
            if [[ "$CERT_STATUS" == "Active" ]]; then
                check_pass "Certificate status: Active"
            else
                check_warn "Certificate status: $CERT_STATUS (may take time to provision)"
            fi
            
            CERT_DOMAIN=$(kubectl get managedcertificate parlant-cert -n $NAMESPACE -o jsonpath='{.spec.domains[0]}' 2>/dev/null)
            check_info "Certificate domain: $CERT_DOMAIN"
        else
            check_info "No ManagedCertificate (HTTP-only mode)"
        fi
    else
        check_fail "Ingress 'parlant-ingress' does NOT exist"
    fi
fi

# ==============================================================================
# 9. Verify Load Balancer Backend Health
# ==============================================================================
section_header "Load Balancer Backend Health"

# Find the backend service associated with the ingress
BACKEND_SERVICES=$(gcloud compute backend-services list --filter="name~parlant" --format="value(name)" 2>/dev/null || echo "")

if [[ -n "$BACKEND_SERVICES" ]]; then
    for BACKEND in $BACKEND_SERVICES; do
        check_info "Found backend service: $BACKEND"
        
        # Check backend health
        HEALTH_STATUS=$(gcloud compute backend-services get-health $BACKEND --global --format="value(status.healthStatus[0].healthState)" 2>/dev/null || echo "UNKNOWN")
        if [[ "$HEALTH_STATUS" == "HEALTHY" ]]; then
            check_pass "Backend '$BACKEND' is HEALTHY"
        elif [[ "$HEALTH_STATUS" == "UNHEALTHY" ]]; then
            check_fail "Backend '$BACKEND' is UNHEALTHY"
        else
            check_warn "Backend '$BACKEND' health: $HEALTH_STATUS"
        fi
    done
else
    check_warn "No backend services found (Load Balancer may still be provisioning)"
fi

# ==============================================================================
# 10. Endpoint Connectivity Test
# ==============================================================================
section_header "Endpoint Connectivity Test"

if [[ -n "$IP_ADDRESS" ]]; then
    echo "    Testing HTTP connectivity to $IP_ADDRESS..."
    
    # Test /healthz endpoint
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "http://$IP_ADDRESS/healthz" 2>/dev/null || echo "000")
    
    if [[ "$HTTP_CODE" == "200" ]]; then
        check_pass "Health endpoint returned HTTP 200"
    elif [[ "$HTTP_CODE" == "000" ]]; then
        check_warn "Could not connect to endpoint (Load Balancer may still be provisioning)"
    elif [[ "$HTTP_CODE" == "502" ]] || [[ "$HTTP_CODE" == "503" ]]; then
        check_warn "Endpoint returned HTTP $HTTP_CODE (backends may not be ready)"
    else
        check_info "Health endpoint returned HTTP $HTTP_CODE"
    fi
else
    check_info "Skipping connectivity test (no IP available)"
fi

# ==============================================================================
# Summary Report
# ==============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                           VERIFICATION SUMMARY                                ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo -e "  ${GREEN}✓ Passed:${NC}   $PASSED checks"
echo -e "  ${YELLOW}⚠ Warnings:${NC} $WARNINGS checks"
echo -e "  ${RED}✗ Failed:${NC}   $FAILED checks"
echo ""

if [[ $FAILED -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✅ ALL CHECKS PASSED! Deployment is fully verified.${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    exit 0
elif [[ $FAILED -eq 0 ]]; then
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  ⚠️  Deployment verified with warnings. Review items above.${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════${NC}"
    exit 0
else
    echo -e "${RED}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}  ❌ DEPLOYMENT VERIFICATION FAILED! Please review failed checks above.${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════════════════════════════════${NC}"
    exit 1
fi
