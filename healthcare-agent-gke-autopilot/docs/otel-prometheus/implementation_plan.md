# Implementation Plan - Enable OpenTelemetry Observability

Enable OpenTelemetry (OTEL) observability for Parlant on GKE Autopilot, exporting traces to Cloud Trace, metrics to Managed Service for Prometheus, and logs to Cloud Logging.

## User Review Required

> [!IMPORTANT]
> **New Components**: OpenTelemetry Collector Deployment (`otel-collector`) with **2 replicas** (HA).
> **Identity Change**: Creating a NEW Service Account `parlant-otel-sa` for strictly scoped observability permissions. `parlant-sa` will NOT be modified.
> **Security**: `otel-collector` runs as non-root user (Autopilot compliant).
> **Drift Prevention**: `redeploy-for-load-testing.sh` will be refactored to patch deployments instead of overwriting them.

## Proposed Changes

### Setup and Infrastructure

#### [MODIFY] [setup.sh](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/setup.sh)
-   **IAM Updates**:
    -   Add `roles/cloudtrace.agent` binding to `parlant-sa` (Project level).
    -   Add `roles/monitoring.metricWriter` binding to `parlant-sa` (Project level).
    -   Add `roles/logging.logWriter` binding to `parlant-sa` (Project level).
-   **Manifest Generation (`k8s-manifests.yaml`)**:
    -   **Add ConfigMap**: `otel-collector-conf` containing:
        -   `receivers`: `otlp` (configured for both `grpc` on 4317 and `http` on 4318).
        -   `processors`: `batch` (send_batch_size: 200, send_batch_max_size: 1000), `memory_limiter` (critical for GKE Autopilot to avoid OOM).
        -   `exporters`: 
            -   `googlecloud`: For traces and logs.
            -   `googlemanagedprometheus`: For metrics.
        -   `service/pipelines`: Connect `otlp` receiver to the respective exporters.
    -   **Add Deployment**: `otel-collector`
        -   Image: `otel/opentelemetry-collector-contrib:0.96.0`
        -   ServiceAccount: `$KSA_NAME` (Reusing `parlant-ksa` which is bound to `parlant-sa`).
        -   Resources: Requests (CPU 250m, Mem 512Mi), Limits (CPU 500m, Mem 1Gi).
    -   **Add Service**: `otel-collector`
        -   ClusterIP, exposing ports `4317` (gRPC) and `4318` (HTTP).
    -   **Update Parlant Deployment**:
        -   Add Environment Variables:
            -   `OTEL_EXPORTER_OTLP_ENDPOINT`: `http://otel-collector:4318`
            -   `OTEL_EXPORTER_OTLP_PROTOCOL`: `http/protobuf`
            -   `OTEL_SERVICE_NAME`: `parlant`
            -   `OTEL_RESOURCE_ATTRIBUTES`: `service.name=parlant,service.namespace=default`
            -   `OTEL_EXPORTER_OTLP_INSECURE`: `true`
    -   **Add Startup Probe**:
        -   To `parlant` deployment (failureThreshold: 30, periodSeconds: 10) to allow time for Vertex AI initialization.

### Verification

#### [MODIFY] [verify.sh](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/verify.sh)
-   **Connectivity Check**: Use a temporary `curlimages/curl` pod to verify internal reachability of `http://otel-collector:13133/health`.
-   **Identity Check**: Verify `parlant-otel-sa` exists and has correct roles.
-   **Resource Check**: Verify `2/2` replicas are Ready for collector.

### Cleanup

#### [MODIFY] [clean-up.sh](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/clean-up.sh)
-   **IAM Cleanup**: Delete `parlant-otel-sa` and its role bindings.
-   **K8s Cleanup**: Ensure `otel-collector` resources are removed (handled by cluster delete, but explicit delete for clarity).

### Load Testing

#### [MODIFY] [redeploy-for-load-testing.sh](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/redeploy-for-load-testing.sh)
-   **Drift Safety**: Refactor `reconfigure_parlant` to use `kubectl set env` or `kubectl patch` to modify the EXISTING deployment instead of overwriting it with a heredoc. This preserves the OTEL config injected by `setup.sh`.
    -   *Logic*:
        1.  Check if `parlant` deployment exists.
        2.  Patch `env` for `USE_VERTEX_AI`, `VERTEX_AI_API_ENDPOINT`, etc.
-   **Revert Logic**: `revert_to_production` should similarly un-patch or restore the specific keys.
    -   *Crucial*: Must explicitly included `startupProbe` definition in the patch to match `setup.sh`, otherwise revert will strip it and cause crash loops.

## Verification Plan

### Automated Tests
-   Run `./verify.sh` to confirm infrastructure health.

### Manual Verification
1.  **Deployment**: Run `./setup.sh`.
2.  **Telemetry Check**:
    -   **Traces**: Visit Cloud Trace > Trace list. Filter by `service=parlant`.
    -   **Metrics**: Visit Monitoring > Metrics Explorer. Query for `parlant_...` metrics or standard `http_server_...` metrics if exposed by Parlant OTLP.
    -   **Logs**: Visit Cloud Logging. Check for logs with `trace` and `spanId` fields populated.
