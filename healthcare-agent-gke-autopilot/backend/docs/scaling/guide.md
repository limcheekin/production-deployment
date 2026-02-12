# Scaling Guide: Parlant on GKE Autopilot

This is a **production-hardening review** of the Parlant deployment on GKE Autopilot. While the current setup provides a functional "Day 1" deployment, it contains architectural gaps that can cause "Day 2" outages under high load. These stem from treating an LLM agent like a standard web app, ignoring the specific behaviors of I/O-bound, long-running, and token-limited workloads.

---

## 1. The "Silent Failure" of CPU-Based Autoscaling

**The Flaw:** The current HPA (`hpa.yaml`) scales on CPU utilization (`averageUtilization: 50`).

**Why it fails:** AI agents are **I/O bound**, not CPU bound.

* **The Physics:** When the agent calls Vertex AI (Gemini 2.5 Flash), the thread waits 10–60 seconds for the response. During this time, the pod's CPU usage drops to near zero (idling on network I/O).
* **The Incident:** A traffic spike hits. You have 500 concurrent users waiting for answers. Your pods are technically "full" (maxed out on async workers), but because they are just *waiting*, CPU usage is low. The HPA sees "5% CPU" and **refuses to scale up**, or worse, **scales down**.
* **The Fix: Scale on Active Requests (KEDA or Custom Metrics).**
    * Scale based on **Active Requests** or **Queue Depth** instead of CPU.
    * On GKE, you can use [KEDA](https://keda.sh/) or the [Custom Metrics Stackdriver Adapter](https://cloud.google.com/kubernetes-engine/docs/concepts/custom-and-external-metrics) with Google Managed Prometheus.
    * Target a concurrency limit per pod (e.g., 20 requests per pod).

    ```yaml
    # Example: KEDA ScaledObject targeting HTTP active requests
    apiVersion: keda.sh/v1alpha1
    kind: ScaledObject
    metadata:
      name: parlant-scaledobject
    spec:
      scaleTargetRef:
        name: parlant
      minReplicaCount: 2
      maxReplicaCount: 10
      triggers:
      - type: prometheus
        metadata:
          serverAddress: http://prometheus:9090
          metricName: http_server_active_requests
          query: sum(http_server_active_requests{app="parlant"})
          threshold: "20"
    ```

---

## 2. The "Interrupted Thought" (Graceful Shutdowns)

**The Flaw:** The current deployment uses the Kubernetes default `terminationGracePeriodSeconds` of **30 seconds**.

**Why it fails:** Agentic workflows (Reasoning → Tool Use → Final Answer) often take 45–90 seconds.

* **The Incident:** A deploy or scale-down event occurs. Kubernetes sends `SIGTERM`, waits 30 seconds, then hard-kills (`SIGKILL`) the pod. A user who has been waiting 40 seconds into a 60-second generation sees a crash. This is a catastrophic UX.
* **The Fix: Extend Termination Grace Period + Add `preStop` Hook.**

    ```yaml
    # In setup.sh Parlant deployment manifest (pod spec level)
    spec:
      terminationGracePeriodSeconds: 120
      containers:
      - name: parlant
        lifecycle:
          preStop:
            exec:
              command: ["sleep", "5"]
    ```

    The `preStop` hook gives the Service time to remove the pod from its endpoint list (stop sending *new* traffic) before SIGTERM is sent, allowing in-flight requests to finish within the 120-second window.

---

## 3. The Database "Connection Storm"

**The Flaw:** Connection counts grow linearly with pods, but database limits are static.

**Why it fails with the current setup:**

* **The Physics:**
    * Standard MongoDB Driver Default: ~100 connections per pod.
    * MongoDB Atlas Free Tier (M0) Limit: **500 connections** total.
    * Even a small M10 tier only allows ~350 connections.
* **The Incident:** Traffic spikes. HPA scales from 2 pods to 5 pods.
    * 5 pods × 100 connections = 500 connections.
    * The database hits its 500 limit and rejects all new connections.
    * **Total System Failure:** Both old and new pods crash simultaneously.
* **The Fix: Strict Math or Proxy.**
    * *Math:* Hard-code your app's `maxPoolSize` using the formula:
      ```
      maxPoolSize = DB_connection_limit / max_pod_count
      ```
      If your DB allows 500 connections and you allow 5 pods, your pool size *must* be ≤ 100. If you scale to 10 pods, it must be ≤ 50.
    * *Proxy:* Use **MongoDB Atlas Proxy** or similar middleware to multiplex thousands of app connections into a few hundred persistent database connections.

---

## 4. Health Check Design

**The Flaw:** Both `livenessProbe` and `readinessProbe` hit the same `/healthz` endpoint (Parlant SDK built-in), which may check external dependencies.

**Why it matters:** Tying pod liveness to external dependency health is dangerous.

* **The Incident:** Vertex AI has a minor outage or high latency. If `/healthz` checks LLM connectivity, it times out. Kubernetes thinks the *pod* is broken and restarts it. The new pod starts, checks Vertex AI, fails, and restarts.
* **The Result:** **CrashLoopBackOff**. Your entire fleet is dead until Vertex AI recovers.
* **The Current Mitigation:** The deployment already has a `startupProbe` with generous budget (`failureThreshold: 60 × periodSeconds: 10 = 600s`), which helps during initial startup. However, the liveness/readiness coupling remains a risk for runtime outages.
* **The Recommended Fix: Decouple Probes** (requires app-level changes in `main.py`).
    * **Liveness Probe:** "Is the Python process running?" (simple HTTP 200 from a custom `/alive` endpoint).
    * **Readiness Probe:** "Can I reach the Database?"
    * **Never** fail a liveness probe because of an external API (Vertex AI) error. Handle that gracefully in the app layer (e.g., return "Service Temporarily Unavailable").

---

## 5. Rate Limiting at the Application Level

**The Flaw:** The current setup relies on Cloud Armor's per-IP rate limiting (100 req/60s), but has no global rate limiting to protect against exceeding LLM provider quotas.

**Why it matters:** LLM APIs have strict rate limits and token quotas. Exceeding them can result in temporary bans or throttling at the provider level, affecting all users.

* **The Fix: Global Rate Limiting.**
    * Implement a **Redis-backed leaky bucket** or **token bucket** algorithm to enforce a global request rate that stays within your Vertex AI quota.
    * This complements Cloud Armor's per-IP limiting by preventing aggregate traffic from overwhelming the LLM provider.

---

## 6. Summary of Recommended Architecture

| Component | Current Strategy | **Production-Grade Strategy** |
| --- | --- | --- |
| **Scaling Metric** | CPU utilization (HPA) | **Active Requests** (via KEDA or Custom Metrics) |
| **Shutdown** | Default (30s) | **`terminationGracePeriodSeconds: 120`** + `preStop` hook |
| **Database** | Direct connection per pod | **Calculated `maxPoolSize`** or **DB Proxy** |
| **Health Checks** | Single `/healthz` for all probes | **Shallow Liveness** (process only) + Deep Readiness |
| **Rate Limits** | Cloud Armor per-IP only | **Global Redis-backed rate limiter** (protect provider quotas) |