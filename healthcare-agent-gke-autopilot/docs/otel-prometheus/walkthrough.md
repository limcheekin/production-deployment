# OpenTelemetry Implementation Walkthrough

We have successfully implemented OpenTelemetry (OTEL) observability for the Parlant application on GKE Autopilot. This setup ensures that traces, metrics, and logs are exported to Google Cloud Trace, Managed Service for Prometheus, and Cloud Logging, respectively.

## Changes Implemented

1.  **OpenTelemetry Collector Deployment**:
    -   Deployed as a scalable **Deployment** with 2 replicas for High Availability.
    -   Configured with `batch` processor and `memory_limiter` to ensure stability and prevent OOMs in GKE Autopilot.
    -   Exposes OTLP gRPC (4317) and HTTP (4318) endpoints.

2.  **Identity & Security**:
    -   Created a dedicated Service Account `parlant-otel-sa` with minimal privileges (`roles/cloudtrace.agent`, `roles/monitoring.metricWriter`, `roles/logging.logWriter`).
    -   Collector runs as a non-root user.

3.  **Parlant Configuration**:
    -   Injected `OTEL_*` environment variables to point Parlant's telemetry to the Collector.

4.  **Stability Improvements**:
    -   **Startup Probe**: Added a `startupProbe` to the `parlant` deployment (both in `setup.sh` and `redeploy-for-load-testing.sh`). This fixed a `CrashLoopBackOff` issue caused by slow Vertex AI initialization exceeding the liveness probe threshold.

5.  **Load Testing Reliability**:
    -   Refactored `redeploy-for-load-testing.sh` to use `kubectl patch` to preserve the OpenTelemetry configuration during load test execution and subsequent reversion to production.

## Verification Results

### 1. Deployment Health
Run `./verify.sh` to confirm the health of all components.

-   **Collector Status**: 2/2 Replicas Ready.
-   **Identity**: Service Account permissions verified.
-   **Connectivity**: Internal connectivity to Collector verified via `curl`.

### 2. Startup & Stability
-   **Issue**: Parlant pods were crashing due to slow startup (Vertex AI init).
-   **Fix**: Added `startupProbe` (failureThreshold: 30, period: 10s = 5mins cushion).
-   **Result**: Pods successfully start and stabilize in both production and load testing modes.

### 3. Load Testing Drift
-   **Test**: Ran `./redeploy-for-load-testing.sh` followed by `./redeploy-for-load-testing.sh --revert`.
-   **Result**: Confirmed that `OTEL_*` environment variables persist through the patch operations, ensuring observability remains active during and after load tests.

## Next Steps needed from User

1.  **Manual Traffic Generation**: Access the application and generate some activity.
2.  **GCP Console Verification**:
    -   **Trace**: Go to **Trace > Trace list** and filter for `service=parlant`.
    -   **Metrics**: Go to **Monitoring > Metrics Explorer** and search for `parlant` metrics.
    -   **Logs**: Check **Logging** for entries with `trace` fields.
