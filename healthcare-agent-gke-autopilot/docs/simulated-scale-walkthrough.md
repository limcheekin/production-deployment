# Simulated Scale Testing Implementation - Walkthrough

## Summary

Successfully implemented load testing infrastructure for the Parlant healthcare agent on GKE Autopilot, adapted for **Vertex AI** and **MongoDB Free Tier (M0)**.

---

## Files Created

### `load_testing/` Directory (9 files)

| File | Size | Purpose |
|------|------|---------|
| [mock_llm_server.py](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/mock_llm_server.py) | 5.3KB | Gemini API compatible mock with streaming SSE |
| [Dockerfile](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/Dockerfile) | 608B | Container for mock server |
| [mock-llm-deployment.yaml](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/mock-llm-deployment.yaml) | 1.7KB | K8s manifests for mock service |
| [locust_load_test.py](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/locust_load_test.py) | 8.7KB | Load test with async polling pattern |
| [locust-deployment.yaml](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/locust-deployment.yaml) | 2.9KB | K8s deployment for Locust master/workers |
| [hpa.yaml](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/hpa.yaml) | 873B | HPA config (max 3 pods for Free Tier) |
| [run-scale-test.sh](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/run-scale-test.sh) | 7.5KB | 4-phase test orchestration script |
| [monitoring-queries.md](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/monitoring-queries.md) | 2.4KB | MQL queries for Cloud Monitoring |
| [__init__.py](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/__init__.py) | 23B | Python package marker |

---

## Files Modified

### [setup.sh](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/setup.sh)

Added NAT port tuning after line 68:

```bash
# 2b. Configure NAT for High Concurrency (Simulated Scale)
gcloud compute routers nats update $NAT_NAME \
    --min-ports-per-vm=4096 \
    --enable-dynamic-port-allocation \
    --max-ports-per-vm=65536 \
    --tcp-established-idle-timeout=300s \
    --tcp-transitory-idle-timeout=30s
```

### [.env.example](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/.env.example)

Added load testing configuration section.

---

## Quick Start

### 1. Deploy Test Infrastructure

```bash
cd healthcare-agent-gke-autopilot
./load_testing/run-scale-test.sh deploy
```

### 2. Run Baseline Test

```bash
./load_testing/run-scale-test.sh baseline
```

### 3. Run All Phases

```bash
./load_testing/run-scale-test.sh all
```

---

## Test Profiles (Free Tier Adjusted)

| Phase | CCU | Duration |
|-------|-----|----------|
| Baseline | 5 | 5 min |
| Knee-Point | 10→50 | 20 min |
| Soak | 30 | 1 hr |
| Chaos | 30 | 10 min |

---

## Key Design Decisions

1. **Mock at Application Level**: Instead of URL redirection (not possible with Vertex AI Workload Identity), the mock is Gemini API compatible.

2. **HPA Limited to 3 Pods**: MongoDB Free Tier has 500 connection limit; 3 pods × 50 connections = 150 (with headroom).

3. **NAT Tuning Always Applied**: Without VPC peering (M0 doesn't support it), all traffic uses NAT, requiring higher port allocation.
