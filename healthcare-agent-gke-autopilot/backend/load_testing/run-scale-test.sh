#!/bin/bash
# =============================================================================
# Simulated Scale Test Execution Script
# =============================================================================
# This script orchestrates the 4-phase load testing methodology for the
# Parlant healthcare agent. Adapted for MongoDB Free Tier constraints.
#
# Prerequisites:
# 1. GKE cluster is running (setup.sh completed)
# 2. Mock LLM service is deployed
# 3. Locust is deployed or available locally
#
# Usage:
#   ./run-scale-test.sh [phase]
#   
#   Phases:
#     1 | baseline   - Baseline validation (5 CCU, 5 min)
#     2 | kneepoint  - Knee-point discovery (10-50 CCU ramp)
#     3 | soak       - Soak test (30 CCU, 1 hour)
#     4 | chaos      - Chaos & recovery test
#     all            - Run all phases sequentially
# =============================================================================

set -e

# Activate virtual environment if it exists (for local testing)
if [ -d ".venv" ]; then
    echo "Activating virtual environment..."
    source .venv/bin/activate
elif [ -d "../.venv" ]; then
    echo "Activating virtual environment (from parent)..."
    source ../.venv/bin/activate
fi

# Configuration
LOAD_TEST_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
LOCUST_FILE="${LOAD_TEST_DIR}/locust_load_test.py"
PROJECT_ID=$(gcloud config get-value project)
REGION="us-central1"
INGRESS_IP=$(gcloud compute addresses describe parlant-global-ip --global --format='value(address)' 2>/dev/null || echo "")
PARLANT_URL="http://${INGRESS_IP}"  # Ingress exposes on port 80
LOCUST_HOST="${LOCUST_HOST:-$PARLANT_URL}"

# Attempt to fetch JWT_SECRET_KEY from K8s if not set locally
if [ -z "$JWT_SECRET_KEY" ] && command -v kubectl &>/dev/null; then
    # Only try if we have access to the cluster
    if kubectl get secret parlant-secrets &>/dev/null; then
        echo "Fetching JWT_SECRET_KEY from cluster..."
        export JWT_SECRET_KEY=$(kubectl get secret parlant-secrets -o jsonpath='{.data.jwt-secret-key}' | base64 -d)
    fi
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Validate prerequisites
check_prerequisites() {
    echo_info "Checking prerequisites..."
    
    if [ -z "$INGRESS_IP" ]; then
        echo_error "Could not find Ingress IP. Is the cluster deployed?"
        exit 1
    fi
    
    echo_info "Target URL: $LOCUST_HOST"
    
    # Check if mock LLM is deployed (optional for Vertex AI testing)
    if kubectl get deployment mock-llm &>/dev/null; then
        echo_info "Mock LLM service detected"
    else
        echo_warn "Mock LLM not deployed. Tests will use live Vertex AI."
    fi
    
    # Check Locust availability
    if ! command -v locust &>/dev/null; then
        echo_error "Locust not found. Install with: pip install locust"
        exit 1
    fi
}

# Phase 1: Baseline Validation
run_baseline() {
    echo_info "=========================================="
    echo_info "Phase 1: Baseline Validation"
    echo_info "  CCU: 5 users"
    echo_info "  Duration: 5 minutes"
    echo_info "  Spawn Rate: 1 user/sec"
    echo_info "=========================================="
    
    locust -f "$LOCUST_FILE" \
        --headless \
        -u "${LOCUST_USERS:-5}" \
        -r "${LOCUST_SPAWN_RATE:-1}" \
        -t "${LOCUST_RUN_TIME:-5m}" \
        --host "$LOCUST_HOST" \
        --csv=results/baseline \
        --html=results/baseline_report.html
    
    echo_info "Baseline complete. Check results/baseline_report.html"
}

# Phase 2: Knee-Point Discovery
run_kneepoint() {
    echo_info "=========================================="
    echo_info "Phase 2: Knee-Point Discovery"
    echo_info "  CCU: 10 -> 50 (ramp by 10 every 5 min)"
    echo_info "  Duration: ~20 minutes"
    echo_info "=========================================="
    
    mkdir -p results
    
    for ccu in 10 20 30 40 50; do
        echo_info "Testing with $ccu concurrent users..."
        
        locust -f "$LOCUST_FILE" \
            --headless \
            -u $ccu \
            -r 2 \
            -t 4m \
            --host "$LOCUST_HOST" \
            --csv=results/kneepoint_${ccu}ccu \
            --html=results/kneepoint_${ccu}ccu_report.html
        
        echo_info "Completed $ccu CCU test. Waiting 1 minute for system stabilization..."
        sleep 60
    done
    
    echo_info "Knee-point analysis complete. Review results in results/ directory."
}

# Phase 3: Soak Test
run_soak() {
    echo_info "=========================================="
    echo_info "Phase 3: Soak Test"
    echo_info "  CCU: 30 users (constant)"
    echo_info "  Duration: 1 hour"
    echo_info "=========================================="
    
    mkdir -p results
    
    locust -f "$LOCUST_FILE" \
        --headless \
        -u 30 \
        -r 5 \
        -t 1h \
        --host "$LOCUST_HOST" \
        --csv=results/soak \
        --html=results/soak_report.html
    
    echo_info "Soak test complete. Check for memory leaks and connection creep."
}

# Phase 4: Chaos & Recovery
run_chaos() {
    echo_info "=========================================="
    echo_info "Phase 4: Chaos & Recovery Test"
    echo_info "  CCU: 30 users"
    echo_info "  Action: Delete 30% of pods after 5 minutes"
    echo_info "=========================================="
    
    mkdir -p results
    
    # Start load test in background
    locust -f "$LOCUST_FILE" \
        --headless \
        -u 30 \
        -r 5 \
        -t 10m \
        --host "$LOCUST_HOST" \
        --csv=results/chaos \
        --html=results/chaos_report.html &
    LOCUST_PID=$!
    
    echo_info "Load test started (PID: $LOCUST_PID)"
    echo_info "Waiting 5 minutes before chaos injection..."
    sleep 300
    
    # Inject chaos: delete random pod
    echo_warn "CHAOS INJECTION: Deleting a Parlant pod..."
    kubectl delete pod -l app=parlant --field-selector=status.phase=Running --wait=false | head -1
    
    echo_info "Waiting for load test to complete..."
    wait $LOCUST_PID
    
    echo_info "Chaos test complete. Review recovery metrics in results/chaos_report.html"
}

# Run locally using Docker Compose
run_local() {
    echo_info "=========================================="
    echo_info "Running Local Scale Test"
    echo_info "=========================================="
    
    # Check for docker-compose or docker compose
    if command -v docker-compose &>/dev/null; then
        DOCKER_COMPOSE="docker-compose"
    elif docker compose version &>/dev/null; then
        DOCKER_COMPOSE="docker compose"
    else
        echo_error "docker-compose not found. Please install Docker Desktop or docker-compose."
        exit 1
    fi
    
    echo_info "Starting services with $DOCKER_COMPOSE..."
    cd "$LOAD_TEST_DIR"
    $DOCKER_COMPOSE up -d --build
    
    echo_info "Waiting for services to be ready..."
    # Simple wait for startup
    sleep 10
    
    echo_info "Checking Mock LLM health..."
    if ! curl -s http://localhost:8000/health > /dev/null; then
         echo_warn "Mock LLM endpoint not reachable on localhost:8000 yet. Waiting..."
         sleep 10
    fi
    
    echo_info "Checking Parlant health..."
    if ! curl -s http://localhost:8800/health > /dev/null; then
         echo_warn "Parlant endpoint not reachable on localhost:8800 yet. Waiting..."
         sleep 10
    fi
    
    cd ..
    
    # Run baseline test against localhost
    export LOCUST_HOST="http://localhost:8800"
    
    echo_info "Running baseline test against local environment..."
    run_baseline
    
    echo_info "Local test complete."
    echo_info "To stop services: cd load_testing && $DOCKER_COMPOSE down"
}



# Main execution
main() {
    mkdir -p results
    
    MODE="${1:-all}"
    
    if [ "$MODE" != "local" ] && [ "$MODE" != "deploy" ]; then
        check_prerequisites
    fi
    
    case "$MODE" in
        1|baseline)
            run_baseline
            ;;
        2|kneepoint)
            run_kneepoint
            ;;
        3|soak)
            run_soak
            ;;
        4|chaos)
            run_chaos
            ;;
        local)
            run_local
            ;;
        deploy)
            echo_info "Delegating deployment to redeploy-for-load-testing.sh..."
            # Execute the robust redeployment script
            ./redeploy-for-load-testing.sh
            ;;
        all)
            echo_info "Running all phases..."
            run_baseline
            run_kneepoint
            # Soak and chaos are optional, run only if baseline/kneepoint pass
            echo_info "Baseline and knee-point phases complete."
            echo_info "Run './run-scale-test.sh soak' or './run-scale-test.sh chaos' manually if needed."
            ;;
        *)
            echo "Usage: $0 [baseline|kneepoint|soak|chaos|deploy|all|local]"
            exit 1
            ;;
    esac
}

main "$@"
