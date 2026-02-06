# Simulated Scale Testing Implementation Plan for Vertex AI

## Problem Statement

The [simulated-scale-guide.md](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/docs/simulated-scale-guide.md) provides a methodology for load testing agentic AI systems, but requires adaptation for your setup:

| Aspect | Guide Assumption | Your Setup |
|--------|-----------------|------------|
| **LLM Provider** | OpenAI API | Vertex AI with Workload Identity |
| **MongoDB Tier** | M30 (3,000 connections) | Free Tier M0 (500 connections max) |
| **Max CCU Target** | 5,000 users | **50 users** (constrained by Free Tier) |

> [!CAUTION]
> **MongoDB Free Tier Limits**: M0 clusters support max 500 connections. With connection pooling overhead, realistic CCU is **~50 users** to avoid `ServerSelectionTimeoutError`.

---

## Proposed Changes

### Component 1: Mock LLM Server

Since Vertex AI uses Workload Identity (not API keys), we deploy a mock that Parlant calls directly. We configure Parlant to use `p.NLPServices.gemini` during testing and redirect API calls to the mock via Kubernetes DNS.

#### [NEW] [load_testing/mock_llm_server.py](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/mock_llm_server.py)

A FastAPI server compatible with **Google Gemini API** format (not OpenAI):
- Endpoint: `POST /v1beta/models/{model}:streamGenerateContent`
- Supports streaming SSE responses with configurable latency
- Injects realistic "thinking time" (Gaussian distribution, 0.5-2.0s)
- Health check endpoint at `/health`

```python
# Key behavior:
# - Random latency injection (simulates LLM thinking)
# - Streaming token generation (50ms inter-token delay)
# - Gemini API compatible response format
# - Proper SSE termination for client connection handling
```

---

#### [NEW] [load_testing/Dockerfile](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/Dockerfile)

Lightweight container for the mock server:
- Base image: `python:3.11-slim`
- Dependencies: `fastapi`, `uvicorn`, `pydantic`
- Runs with 4 uvicorn workers for concurrency

---

#### [NEW] [load_testing/mock-llm-deployment.yaml](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/mock-llm-deployment.yaml)

Kubernetes manifests for the mock service:
- `Deployment` with 2 replicas (sufficient for 50 CCU)
- `Service` at `mock-llm.default.svc.cluster.local:8000`
- Resource requests: 250m CPU, 256Mi memory

---

### Component 2: Cloud NAT Optimization

#### [MODIFY] [setup.sh](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/setup.sh)

Add NAT port allocation tuning for high-concurrency workloads:

```diff
# After line 68 (nat creation):
+# 2b. Configure NAT for High Concurrency (Simulated Scale)
+echo "    - Tuning Cloud NAT for high concurrency..."
+gcloud compute routers nats update $NAT_NAME \
+    --router=$ROUTER_NAME \
+    --region=$REGION \
+    --min-ports-per-vm=4096 \
+    --enable-dynamic-port-allocation \
+    --max-ports-per-vm=65536 \
+    --tcp-established-idle-timeout=300s \
+    --tcp-transitory-idle-timeout=30s --quiet
```

**Rationale**: Default is 64 ports per VM. Without VPC peering (unavailable on M0), all MongoDB traffic also uses NAT, doubling port consumption.

---

### Component 3: Load Testing with Locust

#### [NEW] [load_testing/locust_load_test.py](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/locust_load_test.py)

Locust script implementing the asynchronous polling pattern from the guide:
- `ParlantUser` class with session lifecycle management
- `chat_interaction` task measuring full turn latency
- Proper `min_offset` handling for event polling
- Custom `Full_Turn_Latency` metric via `events.request.fire()`

---

#### [NEW] [load_testing/locust-deployment.yaml](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/locust-deployment.yaml)

Kubernetes deployment for load generation:
- Master pod with web UI (port 8089)
- ConfigMap for `locust_load_test.py`

---

### Component 4: HPA Configuration

#### [NEW] [load_testing/hpa.yaml](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/hpa.yaml)

Horizontal Pod Autoscaler for the Parlant deployment:
- Min replicas: 2
- Max replicas: 3 (limited for Free Tier, each pod uses ~50 connections)
- Target CPU utilization: 50%
- Scale-up policy: 100% increase per 15 seconds

---

### Component 5: Application Integration

#### [MODIFY] [.env.example](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/.env.example)

Add load testing configuration:

```diff
+# Load Testing Configuration (set USE_VERTEX_AI=false for testing)
+# GEMINI_API_KEY=mock-key-any-string
+# Point GOOGLE_GENAI_HOST to mock service for simulated scale testing
```

> [!NOTE]
> During load testing, set `USE_VERTEX_AI=false` and `GEMINI_API_KEY=mock-key`. The Gemini client can be redirected using `GOOGLE_GENAI_HOST` environment variable.

---

### Component 6: Execution Scripts

#### [NEW] [load_testing/run-scale-test.sh](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/run-scale-test.sh)

Orchestration script for the 4-phase test execution (Free Tier adjusted):
- Phase 1: Baseline Validation (5 CCU, 5 min)
- Phase 2: Knee-Point Discovery (10→50 CCU ramp, 20 min)
- Phase 3: Soak Test (30 CCU, 1 hour)
- Phase 4: Chaos & Recovery (30 CCU, pod deletion)

---

#### [NEW] [load_testing/monitoring-queries.md](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/monitoring-queries.md)

MQL queries for Cloud Monitoring dashboard:
- NAT port usage high-water mark
- NAT allocation failures
- Dropped packets (OUT_OF_RESOURCES)

---

## Directory Structure

```
healthcare-agent-gke-autopilot/
├── load_testing/                    # NEW DIRECTORY (underscore for Python imports)
│   ├── mock_llm_server.py           # Gemini-compatible mock
│   ├── Dockerfile                   # Mock container
│   ├── mock-llm-deployment.yaml     # Mock K8s manifests
│   ├── locust_load_test.py          # Load generator
│   ├── locust-deployment.yaml       # Locust K8s manifests
│   ├── hpa.yaml                     # HPA configuration
│   ├── run-scale-test.sh            # Orchestration script
│   └── monitoring-queries.md        # MQL reference
├── setup.sh                         # MODIFIED (NAT tuning)
└── .env.example                     # MODIFIED (new vars)
```

---

## Verification Plan

### Automated Tests

1. **Mock Server Health Check**
   ```bash
   kubectl apply -f load_testing/mock-llm-deployment.yaml
   kubectl wait --for=condition=ready pod -l app=mock-llm --timeout=120s
   kubectl run curl --image=curlimages/curl --rm -it --restart=Never -- \
     curl -s http://mock-llm.default.svc.cluster.local:8000/health
   ```
   Expected: `{"status": "ok"}`

2. **NAT Configuration Verification**
   ```bash
   gcloud compute routers nats describe parlant-nat \
     --router=parlant-router --region=us-central1 \
     --format="value(minPortsPerVm,enableDynamicPortAllocation)"
   ```
   Expected: `4096   True`

3. **Locust Smoke Test**
   ```bash
   locust -f load_testing/locust_load_test.py \
     --headless -u 5 -r 1 -t 1m \
     --host http://YOUR_INGRESS_IP:8800
   ```
   Expected: 0% failure rate, latency ~1-3s (mock delay)

### Manual Verification

1. **End-to-End Mock Integration**
   - Redeploy Parlant with `USE_VERTEX_AI=false` and `GEMINI_API_KEY=mock`
   - Send test message via `/sessions/{id}/events`
   - Verify response includes mock-generated tokens

2. **Load Test Dashboard Review**
   - Monitor NAT port_usage metric in Cloud Monitoring
   - Validate HPA scales before latency degrades

---

## Free Tier Test Profiles (Adjusted)

Due to MongoDB M0 limits, all test phases are scaled down:

| Phase | Original (M30) | Free Tier (M0) | Duration |
|-------|---------------|----------------|----------|
| **Baseline** | 10 CCU | 5 CCU | 5 min |
| **Knee-Point** | 100→2000 CCU | 10→50 CCU (ramp by 10) | 20 min |
| **Soak Test** | 500 CCU, 4-8 hrs | 30 CCU | 1 hr |
| **Chaos** | 1000 CCU | 30 CCU | 10 min |

> [!NOTE]
> **Connection Pool Settings**: With Free Tier and 2-3 pods, each pod can use ~50 connections (total ~150, leaving headroom from 500 limit).

> [!IMPORTANT]
> **VPC Peering Not Available**: M0 clusters don't support VPC peering. All MongoDB traffic routes through Cloud NAT, increasing port consumption.
