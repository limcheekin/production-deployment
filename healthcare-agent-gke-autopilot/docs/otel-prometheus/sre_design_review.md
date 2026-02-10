# SRE Pre-Flight Forensic Review: Parlant OpenTelemetry Implementation

**Role:** Principal SRE & GKE Autopilot Specialist
**Date:** 2026-02-10
**Target:** GKE Autopilot / Healthcare Workload

## 1. The "Red Flags" Forensic Report

| Severity | Issue | Operational Impact |
| :--- | :--- | :--- |
| **CRITICAL** | **Least Privilege Violation** | The plan reuses `parlant-sa` (Vertex AI User) for the Collector. If the Collector is compromised, attackers gain access to your LLM/Vertex AI data. **Fix:** Isolate identity. Create `otel-sa`. |
| **CRITICAL** | **Replication & Availability** | Single `Deployment` replica (`replicas: 1` implied). Updates or crashes will cause telemetry blackouts. **Fix:** Min `replicas: 2` with `PodDisruptionBudget`. |
| **HIGH** | **Configuration Drift Risk** | `redeploy-for-load-testing.sh` uses a hardcoded heredoc. It will actively revert production config updates (like new env vars) during testing. **Fix:** Use `kubectl set env` or `kustomize` overlays instead of heredoc overwrites. |
| **HIGH** | **Autopilot Resource Risk** | `memory_limiter` config is missing specific values. GKE Autopilot hard-kills containers hitting limits. Without a safety buffer (e.g., 80% limit), OOM loops are guaranteed under load. |
| **MEDIUM** | **Verification Blind Spot** | `verify.sh` only checks if Pods exist. It does NOT check connectivity or ingestion. A misconfigured firewall/IAM would pass this check but fail in prod. |
| **MEDIUM** | **Version Hygiene** | `otel-collector-contrib:0.96.0` is older. Use a specific `sha256` digest of a recent stable version (e.g., `v0.100.0` or later) for reproducible builds and security patches. |

## 2. The "Golden Config" Snippets

### A. Memory Limiter (Autopilot Safe)
**Context:** GKE Autopilot has strict resource validation. We must ensure the application throttles itself *before* Kubernetes kills it.

```yaml
# processors section in otel-collector-conf
processors:
  batch:
    send_batch_max_size: 1000
    timeout: 10s
  memory_limiter:
    # 80% of the container hard limit (assuming 512Mi request / 1Gi limit)
    # 1Gi = 1024Mi. 80% = ~819Mi. 
    # check_interval is critical for fast reaction to spikes.
    check_interval: 1s
    limit_mib: 800
    spike_limit_mib: 200 # Approx 25% of limit
```

### B. True Connectivity Verification (`verify.sh`)
**Context:** Don't just check "Running". Check "Reachable".

```bash
echo "    - Verifying Collector Connectivity (Internal)..."
# Use a temporary ephemeral pod to curl the collector's health endpoint
# Note: The collector must have the 'health_check' extension enabled on port 13133
if kubectl run curl-test --image=curlimages/curl --restart=Never --rm -i -- -s -f http://otel-collector:13133/health >/dev/null 2>&1; then
    check_pass "Collector is reachable and HEALTHY on internal network"
else
    # Fallback check for OTLP http endpoint (404/405 is actually GOOD, implies connectivity)
    # Connection Refused is BAD.
    HTTP_CODE=$(kubectl run curl-test --image=curlimages/curl --restart=Never --rm -i -- -s -o /dev/null -w "%{http_code}" -X POST http://otel-collector:4318/v1/traces)
    if [[ "$HTTP_CODE" != "000" ]]; then
       check_pass "Collector OTLP endpoint reachable (HTTP $HTTP_CODE)"
    else
       check_fail "Collector Unreachable (Connection Refused/Timeout)"
    fi
fi
```

## 3. Architecture Decision Record (ADR)

### ADR-001: Telemetry Deployment Strategy

**Decision:** Use **Deployment (Gateway) Pattern** instead of Sidecar.

**Status:** ACCEPTED

**Context:**
We need to collect telemetry from Parlant on GKE Autopilot.

**Alternatives:**
1.  **Sidecar:** Inject Collector into every Parlant pod.
    *   *Pros:* Localhost access, easy to tag with pod metadata.
    *   *Cons (GKE Autopilot):* **Cost Multiplier.** Autopilot charges for pod resource requests. Adding a sidecar increases the minimum CPU/Mem "tax" for *every* replica. Scaling Parlant scales the telemetry layer linearly, which is inefficient for massive traces (sampling should be centralized).
2.  **DaemonSet:** One per Node.
    *   *Cons (GKE Autopilot):* DaemonSets are supported but harder to manage resource guarantees for variable node sizes in Autopilot.
3.  **Deployment (Gateway):** Centralized Service.
    *   *Pros:* Decoupled lifecycle. Can scale independently (HPA) based on telemetry load, not app load. Efficient resource usage.
    *   *Cons:* Network hop (negligible in cluster).

**Consequences:**
*   We will deploy `otel-collector` as a standalone `Deployment` exposed via `ClusterIP`.
*   We MUST configure `replicas: 2` minimum for HA.
*   Identity separation is easier (Collector SA != App SA).

## 4. Remediation Plan
1.  **Refine IAM:** Create distinct `parlant-otel-sa` with only observability roles.
2.  **Harden Collector:** Update manifest with `memory_limiter`, `health_check` extension, and `replicas: 2`.
3.  **Fix Scripts:** Rewrite `redeploy-for-load-testing.sh` to patch configs rather than overwrite. Enhance `verify.sh`.
