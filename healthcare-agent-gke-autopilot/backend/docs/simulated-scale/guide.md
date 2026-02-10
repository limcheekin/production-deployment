# **Operational Guide to Simulated Scale for Agentic AI Architectures on GKE**

## **1\. Introduction: The Deterministic Validation of Probabilistic Systems**

The transition from traditional microservices to agentic Artificial Intelligence (AI) systems represents a fundamental discontinuity in infrastructure reliability engineering. Conventional web applications operate on deterministic principles: a request is received, a database is queried, and a response is serialized, typically within milliseconds. In contrast, AI agents—specifically those constructed using frameworks like Parlant—introduce stochastic latency distributions, stateful conversational sessions, and complex dependency chains involving vector stores, Large Language Model (LLM) inference, and external tool execution.

Validating the scalability of such systems presents a paradox. The primary cost driver and latency bottleneck—the LLM provider (e.g., OpenAI, Anthropic, or Vertex AI)—is an external dependency whose performance characteristics are volatile and whose usage costs are prohibitive at scale. To subject the underlying infrastructure—the Kubernetes networking layer, ingress controllers, database connection pools, and application logic—to rigorous stress testing without incurring massive inference costs, engineering teams must adopt a methodology known as "Simulated Scale."

This comprehensive guide details the architectural principles, implementation strategies, and operational execution plans required to perform high-fidelity load testing of Parlant agents on Google Kubernetes Engine (GKE). By decoupling the "cognitive" layer from the "infrastructure" layer via deterministic mocking, organizations can mathematically verify their system's capacity to handle production-grade concurrency, optimize autoscaling behaviors, and preemptively identify saturation points in critical components like Cloud NAT and MongoDB Atlas.

## ---

**2\. Architectural Theory: The Physics of Agentic Traffic**

To design a valid simulation, one must first analyze the unique "physics" of agentic traffic patterns. Unlike stateless HTTP requests, agent interactions are characterized by prolonged connection durations, high connection concurrency relative to throughput, and distinct resource consumption profiles during "thinking" phases.

### **2.1 The Agent Interaction Lifecycle**

In the Parlant framework, a single user interaction is not an atomic transaction but an orchestrated workflow. When a user message arrives, the system does not simply retrieve data and return; it initiates a multi-stage cognitive pipeline.

1. **Session Hydration**: The agent retrieves the full conversation history and customer profile from the persistence layer (MongoDB), hydrating the session state.  
2. **Guideline Evaluation**: The internal matching engine evaluates active behavioral guidelines against the current context to determine the appropriate response strategy.  
3. **Inference Request**: The system constructs a prompt and dispatches it to the NLP service. This phase introduces the most significant variability, as the system waits for token generation.  
4. **Tool Execution**: If the model dictates a tool call (e.g., "check\_balance"), the agent executes the function, potentially awaiting third-party API responses, and then re-prompts the model with the result.  
5. **Response Delivery**: The final generated text is streamed or returned to the user via the POST /sessions/{id}/events polling mechanism.

### **2.2 The Hold-Time Concurrency Multiplier**

The critical metric in this architecture is not Requests Per Second (RPS) but Concurrent Users (CCU). Because LLM inference is computationally expensive and slow—often taking 5 to 30 seconds for complex reasoning tasks—the application server must maintain active state for the duration of this "hold time."

Consider a standard web application serving 1,000 requests per second with a 50ms latency. The number of concurrent requests is approximately:

![][image1] requests.

In an agentic system serving the same 1,000 requests per second, but with a 10-second average latency due to LLM generation and tool execution, the concurrency requirement explodes:

![][image2] active requests.

This 200x increase in concurrency fundamentally changes the stress applied to the infrastructure. It exhausts file descriptors, saturates thread pools (or asyncio event loops), and, critically, depletes ephemeral ports on the NAT gateway.

### **2.3 The Failure Domains**

Simulated Scale focuses on stressing specific failure domains that are invisible in low-volume testing:

* **Network Address Translation (NAT) Saturation**: GKE nodes in private subnets route all egress traffic (to OpenAI, MongoDB, etc.) through Cloud NAT. High concurrency workloads often exhaust the available source ports, leading to packet drops.  
* **Database Connection Storms**: Rapid autoscaling of agent pods can trigger a flood of new connection attempts to MongoDB, potentially exceeding the maxIncomingConnections limit of the Atlas cluster.  
* **Autoscaler Hysteresis**: The Horizontal Pod Autoscaler (HPA) may lag behind traffic spikes if configured solely on CPU utilization, as the application is often waiting on I/O (network calls to the LLM) rather than burning CPU cycles.

## ---

**3\. Infrastructure Architecture & Preparation**

The test environment must mimic the production architecture described in the provided deployment guide. Deviations here will render the test results invalid.

### **3.1 Network Topology and Cloud NAT Configuration**

The primary bottleneck for high-concurrency agent workloads is the mapping of internal IP addresses to external IP addresses. Cloud NAT uses a table of 5-tuples (Protocol, Source IP, Source Port, Destination IP, Destination Port) to track connections.

**The Port Math:**

Each external IP address on a Cloud NAT gateway offers 64,512 usable ports (UDP and TCP). If a single GKE node hosts 20 agent pods, and each pod opens 50 concurrent connections to the LLM provider, the node requires:

![][image3] ports.

By default, Cloud NAT may allocate as few as 64 ports per VM instance. If the load test exceeds this allocation, the NAT gateway will drop packets, causing ETIMEDOUT or Connection Reset errors in the application logs.

**Configuration Strategy:**

To support Simulated Scale, the Cloud NAT must be explicitly tuned:

1. **Dynamic Port Allocation**: Enable this feature to allow the gateway to automatically assign more ports to nodes with higher demand, up to a specified maximum.  
2. **Minimum Ports Per VM**: Increase this value based on the anticipated peak concurrency. For a target of 5,000 concurrent users, setting min\_ports\_per\_vm to 4,096 or 8,192 is recommended to provide substantial headroom.  
3. **Timeouts**: Reduce tcp\_transitory\_idle\_timeout to 30s to reclaim ports faster from short-lived connections, while ensuring tcp\_established\_idle\_timeout is sufficient for any long-polling mechanisms.

### **3.2 Persistence Layer: MongoDB Atlas Integration**

The Parlant framework relies heavily on MongoDB for session state and customer data. In a load test, the database experiences a write-heavy workload as every user message, agent thought process, and tool result is persisted.

**Network Peering:**

It is imperative to configure VPC Peering between the Google Cloud VPC and the MongoDB Atlas VPC. Using the standard public internet connection string forces all database traffic through the Cloud NAT gateway, doubling the pressure on the NAT ports (once for the LLM, once for the DB) and introducing unnecessary latency variance.

**Connection Pooling Formula:**

The Parlant server uses an asynchronous MongoDB driver. You must calculate the maxPoolSize to prevent overwhelming the Atlas cluster.

Let ![][image4] be the max connections supported by your Atlas tier (e.g., M30 supports 3,000 connections).

Let ![][image5] be the maximum number of Parlant pods you expect to scale to.

The pool size limit (![][image6]) per pod should be:

![][image7]  
*Example*: For M30 (3000 conns) and 20 pods: ![][image8]. Set minPoolSize=10 and maxPoolSize=120.

### **3.3 Compute: Workload Identity Federation**

Authentication logic must mirror production. We utilize GKE Workload Identity to map Kubernetes Service Accounts (KSA) to Google Service Accounts (GSA). This ensures that the simulated load tests valid authentication paths for services like Vertex AI (if used) and simplifies credential management. During the simulation, even if the "LLM" is mocked, the application may still need to authenticate against other GCP services (e.g., Pub/Sub or Secret Manager).

## ---

**4\. The Mocking Strategy: Decoupling Intelligence from Infrastructure**

The defining innovation of the "Simulated Scale" methodology is the abstraction of the LLM. Running a load test against the actual OpenAI API is technically unsound for infrastructure validation due to external rate limits, variable latency that masks internal bottlenecks, and extreme cost.

We must replace the LLM with a **High-Fidelity Deterministic Mock Service** that replicates the behavioral signature of an LLM without the cognitive processing.

### **4.1 Specification of the Mock Service**

The mock service acts as a "stand-in" for the NLP provider. It must intercept HTTP requests targeted at the LLM API endpoints (e.g., /v1/chat/completions) and return valid, provider-compatible JSON responses.

**Key Behavioral Requirements:**

* **Latency Injection**: The mock must simulate the "time to first token" and "total generation time" of a real LLM. This is achieved by injecting a sleep delay, ideally modeled on a probabilistic distribution (e.g., Gaussian or Log-Normal) rather than a fixed constant, to prevent artificial synchronization of request patterns.  
* **Streaming Support (Critical)**: Real LLM interactions use Server-Sent Events (SSE). The mock *must* stream responses chunk-by-chunk. This keeps the HTTP connection open for seconds, correctly stressing the GKE Ingress controller and NAT tables. Returning a payload instantly does not simulate the resource holding cost of a real agent.  
* **Payload Fidelity**: The response body must match the schema expected by the Parlant SDK (e.g., OpenAI Chat Completion object), including choices, message, and usage fields.  
* **Tool Call Simulation**: To test the complex code paths involving tool execution, the mock must be capable of returning responses that trigger the tool-use logic in Parlant (e.g., returning tool\_calls instead of content).

### **4.2 Implementation Details: Python & FastAPI**

The mock server should be a lightweight, asynchronous Python application deployed within the Kubernetes cluster.

**Mock Implementation Logic (Streaming):**

The server intercepts POST requests to the completion endpoint. Instead of processing the input tokens, it:

1. Parses the request to determine if a specific behavior is requested.  
2. If stream=True, it enters a generator loop.  
3. Sleeps for inter\_token\_delay (e.g., 50ms) between chunks.  
4. Yields JSON chunks formatted as data: {...}\\n\\n.  
5. **Crucial**: Ends with data:\\n\\n to signal the Parlant client to close the connection properly.

**Deployment Configuration:**

The Parlant agent is reconfigured to point to this internal service using standard SDK environment variables.

| Variable | Production Value | Simulation Value |
| :---- | :---- | :---- |
| OPENAI\_BASE\_URL | https://api.openai.com/v1 | http://mock-llm.default.svc.cluster.local:8000/v1 |
| OPENAI\_API\_KEY | sk-... | sk-mock-key-any-string |

This configuration directs all inference traffic to the mock, allowing the infrastructure to scale based on the connection concurrency and request volume defined by the load generator.

## ---

**5\. Designing the Load Generator: The Locust Strategy**

Locust is the selected tool for load generation due to its Python-based scripting capability, which allows for complex, stateful user scenarios. However, testing an asynchronous conversational interface requires a sophisticated implementation pattern beyond simple "fire-and-forget" HTTP requests.

### **5.1 The Asynchronous Polling Pattern**

Parlant uses an asynchronous event-driven API. A client posts a message (Event A) and subsequently polls an endpoint to receive the agent's response (Event B). Standard HTTP load testing measures the time to complete the POST request, which is nearly instantaneous. This is insufficient. We must measure the **Transaction Latency**: the time elapsed between the user sending a message and the user receiving the agent's reply.

**The Polling Workflow:**

1. **Session Creation**: The simulated user initializes a session.  
2. **Message Injection**: The user posts a message event.  
3. **Polling Loop**: The user enters a loop, repeatedly calling GET /sessions/{id}/events with a min\_offset parameter.  
4. **Completion Detection**: The loop terminates when an event of type status=ready or kind=message (from the agent) is detected.  
5. **Latency Calculation**: The total time spent in the loop is recorded as the response time.

### **5.2 Locustfile Implementation Guide**

The locustfile.py script orchestrates this logic. We utilize the FastHttpUser class for efficiency and implement a custom task that manages the polling lifecycle.

**Critical Code Logic (Optimized for Long-Polling):**

The simulated user must handle the min\_offset correctly to avoid re-fetching old events. The wait\_for\_data parameter in the Parlant API allows the server to hold the request open until a new event arrives (long-polling), which is far more efficient than tight loops and better reflects real client behavior.

Python

import time  
from locust import task, FastHttpUser, events

class ParlantUser(FastHttpUser):  
    \# Simulating a user session  
    def on\_start(self):  
        \# Create a new session for this user  
        response \= self.client.post("/sessions", json={"agent\_id": "production\_agent"})  
        self.session\_id \= response.json()\["id"\]  
        self.last\_offset \= 0

    @task  
    def chat\_interaction(self):  
        \# 1\. Send User Message  
        start\_time \= time.time()  
        self.client.post(  
            f"/sessions/{self.session\_id}/events",  
            json={"kind": "message", "source": "customer", "message": "Hello world"}  
        )

        \# 2\. Poll for Agent Response  
        \# We loop until we get a reply, utilizing Parlant's long-polling 'wait\_for\_data'  
        while True:  
            \# wait\_for\_data=10 holds the connection for up to 10s if no new events  
            with self.client.get(  
                f"/sessions/{self.session\_id}/events",  
                params={"min\_offset": self.last\_offset, "wait\_for\_data": 10},  
                catch\_response=True,  
                name="/sessions/{id}/events (poll)"  
            ) as response:  
                if response.status\_code\!= 200:  
                    response.failure("Polling failed")  
                    break  
                  
                event\_list \= response.json()  
                if not event\_list:  
                    continue \# Long poll timed out with no data, retry  
                  
                \# Update offset to avoid fetching these again  
                self.last\_offset \= max(e\['offset'\] for e in event\_list) \+ 1  
                  
                \# Check for agent response  
                agent\_replied \= any(e\['source'\] \== 'ai\_agent' and e\['kind'\] \== 'message' for e in event\_list)  
                  
                if agent\_replied:  
                    total\_duration \= (time.time() \- start\_time) \* 1000  
                    \# Record the full turn latency manually  
                    events.request\_success.fire(  
                        request\_type="Conversation",  
                        name="Full\_Turn\_Latency",  
                        response\_time=total\_duration,  
                        response\_length=0  
                    )  
                    break

This pattern ensures that the metric reported by Locust reflects the actual user experience, including the "thinking" time injected by the mock server and the processing overhead of the Parlant engine.

### **5.3 Workload Modeling**

A monolithic load profile is unrealistic. We define three user classes to model production variance:

* **The "Chatter"**: Sends frequent, short messages. High impact on ingestion throughput and guideline matching.  
* **The "Thinker"**: Sends complex queries that trigger tool calls (simulated by specific mock responses). High impact on "hold time" and memory usage.  
* **The "Idler"**: Connects, sends one message, and maintains an open session. High impact on memory and database connection pools due to idle session state management.

## ---

**6\. Observability Framework: The Signal in the Noise**

Before initiating load, a robust observability framework must be established. Scaling blindly is worse than not scaling at all. We rely on Google Cloud Monitoring (MQL) and application-level metrics to visualize system health.

### **6.1 Critical Network Metrics (Cloud NAT)**

Monitoring Cloud NAT is non-negotiable. We use Monitoring Query Language (MQL) to create precise alerts for port exhaustion.

**Metric: Port Usage High-Water Mark**

This query reveals the maximum number of ports consumed by any single VM instance in the cluster.

SQL

fetch gce\_instance

| metric 'router.googleapis.com/nat/port\_usage'  
| group\_by \[resource.zone\], max(val())

*Interpretation*: If max(val()) approaches the configured min\_ports\_per\_vm (e.g., \>80%), the node is nearing exhaustion. The system will soon start dropping packets.

**Metric: Allocation Failures**

This is the definitive failure signal.

SQL

fetch nat\_gateway

| metric 'router.googleapis.com/nat/nat\_allocation\_failed'  
| align rate(1m)  
| every 1m

*Interpretation*: Any value greater than zero indicates that connections are being rejected because the NAT gateway cannot allocate ports. This invalidates the test results as the bottleneck is network egress, not the application.

### **6.2 Database Metrics (MongoDB Atlas)**

Monitoring the persistence layer requires correlating application load with database performance.

* **Connection Usage**: Track mongodb.connections.current. A sudden plateau usually indicates the application driver's maxPoolSize has been reached.  
* **Ticket Queues**: Monitor read/write tickets. A spike in queued tickets implies the database CPU or I/O is saturated and cannot process requests fast enough.  
* **Op Execution Time**: If this metric increases linearly with user load, the database creates backpressure. If it remains flat while application latency rises, the bottleneck is likely in the application compute layer.

## ---

**7\. Execution Guide: Running the Simulated Scale**

The simulation is executed in four distinct phases, each designed to answer specific questions about the architecture's limits.

### **Phase 1: Baseline Validation (The Smoke Test)**

**Objective**: Verify the test harness integrity and Mock LLM connectivity.

**Configuration**: 1 Parlant Pod, 1 Mock LLM Pod.

**Load Profile**: 10 Concurrent Users (CCU), Spawn Rate 1 user/sec.

**Duration**: 10 minutes.

* **Hypothesis**: The system should handle this load with negligible error rate. Latency should equal the configured mock sleep time plus a small overhead (\~50-100ms).  
* **Validation**:  
  * Check Parlant logs: Ensure requests are hitting the Mock URL (http://mock-llm...) and not the real OpenAI API. Verify no API keys are being rejected.  
  * Check Locust UI: Verify 0% failure rate.  
  * Check Cloud NAT: Port usage should be minimal.

### **Phase 2: The Scalability Knee-Point (Linear Ramp)**

**Objective**: Identify the concurrency level where performance begins to degrade (the "knee").

**Configuration**: Autoscaling Enabled (HPA). Min Replicas: 2, Max Replicas: 10\. HPA Trigger: CPU \> 50%.

**Load Profile**: Start at 100 CCU, ramp up by 100 users every 5 minutes until 2,000 CCU.

**Duration**: 100 minutes (variable based on ramp).

* **Hypothesis**: As load increases, HPA should spawn new pods. Latency should remain stable until a bottleneck (NAT, DB, or Max Replicas) is hit.  
* **Analysis**:  
  * **HPA Reaction**: Does the cluster scale out fast enough? If latency spikes significantly before new pods become Ready, tune the HPA behavior block to allow faster scale-up (e.g., policies: \- type: Percent, value: 100, periodSeconds: 15).  
  * **NAT Pressure**: Watch the port\_usage metric. As pods scale out, they consume ports linearly. If port usage hits the limit before CPU triggers the HPA, the system is network-bound.

### **Phase 3: The Soak Test (Endurance)**

**Objective**: Detect memory leaks, resource exhaustion, and stability over time.

**Configuration**: Fixed Scale (e.g., 5 Pods). Autoscaling Disabled to maintain constant pressure.

**Load Profile**: Constant load of 500 CCU.

**Duration**: 4 to 8 hours.

* **Hypothesis**: System resources (Memory, DB Connections) should remain stable (flat line) throughout the test.  
* **Analysis**:  
  * **Memory Creep**: If container memory usage grows slowly but steadily, the Python application may be leaking objects (e.g., unclosed sessions or tasks).  
  * **Connection Leaks**: Monitor mongodb.connections.current. If this climbs over hours without a corresponding increase in load, connections are not being returned to the pool.

### **Phase 4: The Chaos & Recovery Test**

**Objective**: Validate system resilience and recovery speed.

**Configuration**: Steady state load (1,000 CCU).

**Action**: Manually delete 30% of the Parlant pods (kubectl delete pod \-l app=parlant).

**Duration**: 20 minutes post-deletion.

* **Hypothesis**: In-flight requests may fail (unless retries are configured), but the system should self-heal. HPA should replace pods, and users should reconnect seamlessly.  
* **Analysis**:  
  * **Recovery Time Objective (RTO)**: Measure the time from pod deletion until error rates return to zero.  
  * **Session Persistence**: Verify that after reconnection, the Locust users can continue their conversation context (retrieved from MongoDB) without resetting the session.

## ---

**8\. Capacity Planning & Analysis**

Post-execution, the data gathered informs the production capacity model.

### **8.1 Interpreting the Data**

| Observation | Root Cause | Remediation |
| :---- | :---- | :---- |
| **High Latency, Low CPU** | Application is I/O bound. It is waiting for the Mock LLM or Database. | Increase pod count based on custom metrics (e.g., active requests) rather than CPU. Check Mock server capacity (scale the mock\!). |
| **504 Gateway Timeout** | Ingress controller or Load Balancer timeout is shorter than the "thinking" time. | Configure GKE BackendConfig to increase timeoutSec to \>300s (5 mins). |
| **Connection Reset / Network Error** | Cloud NAT port exhaustion. | Increase min\_ports\_per\_vm in Cloud NAT. Check nat\_allocation\_failed metric. |
| **DB Connection Errors** | MongoDB connection pool saturation. | Increase maxPoolSize in application config. Upgrade Atlas tier if CPU is high. |

### **8.2 Production Tuning**

The values derived from the "Knee-Point" test (Phase 2\) dictate the production resource requests.

* **CPU Request**: Set to the usage observed at optimal concurrency.  
* **Memory Request**: Set to the peak usage observed during the Soak Test \+ 20% buffer.  
* **HPA Target**: If the system became unstable at 70% CPU, set the HPA target to 50% to provide a safety margin for burst traffic.

## ---

**9\. Detailed Configuration Reference**

This section provides the concrete artifacts required to implement the strategy.

### **9.1 The Mock Server (Python/FastAPI with Streaming)**

This server simulates the OpenAI API contract, including token streaming to exercise connection holding. **Important**: You must run this with multiple workers (e.g., uvicorn main:app \--workers 4\) or run multiple replicas in Kubernetes, otherwise the mock itself will become the bottleneck.

Python

\# main.py  
import asyncio  
import random  
import time  
import json  
from fastapi import FastAPI, Request  
from fastapi.responses import StreamingResponse  
from pydantic import BaseModel

app \= FastAPI()

class ChatCompletionRequest(BaseModel):  
    model: str  
    messages: list  
    stream: bool \= False

async def fake\_data\_streamer(model):  
    \# Simulate thinking delay (latency)  
    await asyncio.sleep(random.uniform(0.5, 2.0))  
      
    \# Simulate token generation (throughput \+ holding connection)  
    for i in range(20):  
        chunk \= {  
            "id": "chatcmpl-mock",  
            "object": "chat.completion.chunk",  
            "created": int(time.time()),  
            "model": model,  
            "choices": \[{  
                "index": 0,  
                "delta": {"content": f" token\_{i}"},  
                "finish\_reason": None  
            }\]  
        }  
        yield f"data: {json.dumps(chunk)}\\n\\n"  
        \# Simulate inter-token latency (e.g., 50ms)  
        await asyncio.sleep(0.05)  
      
    \# Send done signal (Critical for proper client termination)  
    yield "data:\\n\\n"

@app.post("/v1/chat/completions")  
async def mock\_completions(request: ChatCompletionRequest):  
    if request.stream:  
        return StreamingResponse(fake\_data\_streamer(request.model), media\_type="text/event-stream")  
      
    \# Fallback to non-streaming for simple checks  
    await asyncio.sleep(random.uniform(1.0, 3.0))  
    return {  
        "id": "chatcmpl-mock-123",  
        "object": "chat.completion",  
        "created": int(time.time()),  
        "model": request.model,  
        "choices":,  
        "usage": {"prompt\_tokens": 10, "completion\_tokens": 10, "total\_tokens": 20}  
    }

@app.get("/health")  
async def health():  
    return {"status": "ok"}

### **9.2 Mock Service Deployment**

Deploy the mock internally. Note the high replica count to ensure it handles the load.

YAML

\# mock-llm-service.yaml  
apiVersion: v1  
kind: Service  
metadata:  
  name: mock-llm-service  
spec:  
  selector:  
    app: mock-llm  
  ports:  
    \- protocol: TCP  
      port: 8000  
      targetPort: 8000  
\---  
apiVersion: apps/v1  
kind: Deployment  
metadata:  
  name: mock-llm  
spec:  
  replicas: 5 \# Scale this up if testing \> 2000 CCU  
  selector:  
    matchLabels:  
      app: mock-llm  
  template:  
    metadata:  
      labels:  
        app: mock-llm  
    spec:  
      containers:  
      \- name: mock-llm  
        image: python:3.10-slim  
        command: \["/bin/sh", "-c"\]  
        args: \["pip install fastapi uvicorn pydantic && uvicorn main:app \--host 0.0.0.0 \--port 8000 \--workers 4"\]  
        volumeMounts:  
        \- name: code  
          mountPath: /app  
        workingDir: /app  
        \# Add simple readiness probe  
        readinessProbe:  
          httpGet:  
            path: /health  
            port: 8000  
      volumes:  
      \- name: code  
        configMap:  
          name: mock-llm-code

### **9.3 Cloud NAT Monitoring Dashboard (MQL)**

Use these queries in the Google Cloud Console "Metrics Explorer" to build a dedicated dashboard for the test.

**Table 1: Essential MQL Queries**

| Metric Name | MQL Query | Alert Threshold |
| :---- | :---- | :---- |
| **Port Allocation Failures** | fetch nat\_gateway | metric 'router.googleapis.com/nat/nat\_allocation\_failed' | align rate(1m) | every 1m | \> 0 |
| **Dropped Packets (Out of Resources)** | fetch gce\_instance | metric 'router.googleapis.com/nat/dropped\_sent\_packets\_count' | filter metric.reason \== 'OUT\_OF\_RESOURCES' | align rate(1m) | \> 0 |
| **Max Port Usage per VM** | fetch gce\_instance | metric 'router.googleapis.com/nat/port\_usage' | group\_by \[resource.zone\], max(val()) | \> 80% of min\_ports |

## ---

**10\. Conclusion**

The "Simulated Scale" methodology transforms the validation of AI agents from a costly, unpredictable experiment into a controlled engineering discipline. By acknowledging the unique physics of agentic traffic—specifically the high-concurrency, long-hold characteristics—and meticulously preparing the infrastructure to handle it, organizations can deploy Parlant agents with confidence.

The use of a deterministic Mock LLM is the linchpin of this strategy. It allows for the isolation of infrastructure variables, ensuring that when the system scales, it is limited only by provisioned capacity and not by architectural defects in networking or state management. Through the rigorous execution of Baseline, Knee-Point, Soak, and Chaos tests, engineering teams generate the empirical data necessary to tune GKE, Cloud NAT, and MongoDB for the harsh realities of production traffic.

This guide serves not just as a testing manual, but as a blueprint for the mature operational management of Generative AI systems in the enterprise.

### ---

**Appendix: Troubleshooting Runbook**

**Issue: High Failure Rate in Locust (Connection Refused)**

* **Check**: Is the load balancer or ingress controller overwhelmed?  
* **Action**: Check GKE Ingress logs. If using NGINX Ingress, check for worker\_connections exhaustion. If using Google Cloud Load Balancer, check for backend healthiness.

**Issue: Locust reports "0" latency**

* **Check**: The polling loop logic in locustfile.py.  
* **Action**: Ensure the loop waits for a status=ready event. If the code returns immediately after the POST request, it is not measuring the full turn latency.

**Issue: Pods crash with OOMKilled**

* **Check**: Memory usage per pod vs. limits.  
* **Action**: Python processes can bloat. Increase memory limits in the deployment YAML. Ensure the asyncio loop is not accumulating unawaited coroutines.

**Issue: "pymongo.errors.ServerSelectionTimeoutError"**

* **Check**: VPC Peering status and firewall rules.  
* **Action**: Verify that the GKE subnet has a route to the Atlas peering connection. Check that the Atlas IP Access List allows the GKE subnet CIDR (private IP), not the NAT IP (public IP).

[image1]: <data:image/png;base64,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>

[image2]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAS8AAAAYCAYAAACr1nt5AAAKO0lEQVR4Xu2cB7AlRRWGf7OYUBQVLWUBMZU5gHlXQEGwRDHHXUXEnANiAkxgQikVV8UFFXNOIIqCopilFLUMyCsBRaWMpRZSlJ5vT5+5Pf1m7u33qrh3q7a/qlN75/TM3Onp7r9Pn75vpUaj0Wg0Go1Go9FoNBqNy4SdSkfG3c0+ZXa62Wlm9+mVOjc0O87s62bfNTuoX9zxeLOTzL5t9jGzHfvFc+emZlconYnaOs2bbc22K52JK5odYfY1sx+avclsm94ZddTWvaY9a+/VaFRzTbN1Zu81+2u/qONuZheY7ZaO9zL7j9ke3RnS9cx+Yvb0dHwTs1+bHRYnJCg/y+z66fiVZhdmx/PiymZ3lD/fRWZ36ZU6tXWaF5cz21U+8H9u9vx+cceHzT4oF7Grmn1OLmQrobbuNe1Ze69BUEJuiur91uxMs5+aPSmVo8xr0+fG1sMdzP5o9iH5YPhbv7jj+2bHFL4T5YMieLO8g+Y8VS4MV0rHN5CL3sO7M6TLm51n9qLMNw/4zi+ZfcXsfxoWr5o6zZOPmp1h9gH5Mw+J1/7yslw8bp18u2e+WdTUvbY9a+41yCvM/i0P6fY2u0ryEyYTWtIxKUehG1svn9eweDHT0/GfWfhfZfYP+ewOS/LBlUNkxrX3TscHpuPbdWc4XzU7ufDNixdrXLyWNLtOi4BIeEy8TpBPSDm00aVmhxb+aSxpdt1r23NJs++1jPfJT3hWWZCgUjEDNbZuxsTrkfI+9LjC/7zkXyvPZ/B5Y+8M6c7J//J0/PZ0zLIhh1zaPzV7Aj1AvnQaY1/NmMkHGBOv2jotgmniRYTzi9IpTwmcUjpHqK17TXvW3qvHs+WFLBengULSERtbN2PixQChHyFiOc9IflIPDHw+05lzbpv8m9Lxp9MxHTrnI8m/S+EvIfp7delMvEA+QKaJ2xBj4lVbp0UwTbxow3KJBuShzimdI9TWvaY9a+/VwXr37/Kk2KyZ6Eizm5dO4wFmnzX7jtlf5Ovsq6UyhBF1/7jZtc1eIg8Lv2d2rHwnpITlB5X6lfy+7zG7sfzcd8tzD6yN887HkjfPq6DwXPcb+Zr5cPmg+7L8ZQAd/FR5gpJG5gUTxr42lQfXlS+buZY8AiJ+nVR2X/lymqU292W5/Qmzb6R/47tyxuoHL5U/B+9r++QDQuZfanrE8WN5I9faa/yyFTMmXsyM3LcUL94//oPl0Refyw4auRaSx8DMz3HZ2cmf4b9V4R/iLZrkagOWIDz/2I7hNMbEq7ZOQ0S0sRK7/+Yr65gmXviHxIsNl/NL5whrVVf3mvasvVcHDUzBaiIqxONoeQI3OhOJOdbRR5nd0uytZjeTf8fZZvdI5+2QfHTsHAY/+ZFD5GLKoL1EvgZ/v3wbfj9NKgwk/n4v3zkJqOjOmrycp8iFF8Ggzly7SZMXw6YE4sqA5ng7OXua/Un9pRDX89w8H2Ev/7K58Tu5IIaock++P2da/RhoJC/Z1eMZYscF3iX/ji2BMfFiYuK5S/FCtPCT96D9hjoo7YGfPAx8IR2XnZ12xc8EMAv6BRsMj03HfDcT37W6M1bGmHjV1mkRTBMv8tdD4oVwnVs6R6ite0171t6rg6iIAraCV8ph8msRgBwiDgYa0cpuZg+VnxedCIgq8OXiRfTBwCYSCe4pj3jY7eIFwCa5oESkSBn3YpAAGw0RhSGsdFi4vVxM1siTyNybZ+LadekcdlNDNBDdi5MPEKW7yvN+/N5nH7PnalIXBCaHSCgXr2n1u4082trG7Iny+4XQw7kaaLwFgXgRrZccJH/uRxV+3if+A8xukT6/o3eG1x8/kyHELhmTXA4TFH6i4RrI1RLl0t5E2RExr4YQL/pATm2dFkGIF0vlEiZbJtiSP8h/81VDbd1r2rP2XpthkONkC3NWGP0I9ZNt15An2oYSeywJeTHB2+TnhtjAevl3IxDBMcnHCx+Dzvcvs3dmvsjZUfkcxAL/0KwTIDgsdYfqH1Ep0RXL0o1ysSK6zHmY/LxcbNYkX75sqakffFP9RCqzEtc9LfMtkjHxiklqQ+Fn4OBfJ/8dD5+Py0+QCwJ+3jMQsXO8U3eG85nkJ6qqhaX9n82eUxaskDHxqq3TIpgmXj+Sp4tKaNuY8GdRW/ea9qy9V8eSvIAZfwzyV1Qm7zAPll9HjiYHwbhUrrQBL4ncTs5J8kGag+gRUcWya4jY0aJDBojLUnYcRFRF9DcGkVn5bAHPyPJo1kChYdihYZYPeC+E5SxFg5r6IYxlQ0XkQuQ4jZXmvIiMVwPiRQRZskZ+XwQ+5/XyCTLeBUv3T06KN0PelGv3Tcfr0/GdujOcM8y+VfimcS95TpKBQRT8mH7xigjxGupPNXUaYjU5r702X1lHiNcLywIN/9iYsc755Ldrqan7+nQ8qz1r7tVBB6aAkH4Icj8swfYo/A+UX/egwv+G5Gf9CjEY2XEK1iQfeSginkjEUYkz0+ccchQxcMlJEXmFUPAvkRMNwb1y0SS5j/jkopLD0o/nIM80xCZ5krwkfx44S740CRAnIqd4FqJE3mNN/UjG8kwsJwOW4UQOs0R0XiBeRNJDnK7+shjoP9QhoA15r7mI0wYsVyI6J8JGIJ/QneG/dL9I9REUfZDv2TkdR/9YrYCFeO1eFqiuTosgxGuoj99PXrZj5qNupcjQFqQyhlYnUFP32vasuVcHyz9yLhdo+d+gMWudLM8plVxdntfKE/10ikvUn3kfLX8Z+fIwoieWoSyrEDFg+YcwbZ+OgWdi5gwxRASZxWPXjQR5NM5a9Z/nfHlYOsYG+bXlMiBAoC9WP6fH0pRd1Vgi3kh+j3x5GLMpSX42LY5P/pr6RXIyJgvagEiWfNiWAlE49aAPlLAsOEf+XoB3x+SSL+lpO4Sc6B2I+plxy9+HUc4ubgwacmpEl9N2XAOS6gwC8iU5TGRE2uWmQg38lIi22bMsUH2d5g0rFJ758LIgQT6X9EiAuG/MjoHggnuUEXVQW/ea9qy9VwcNukH+R7QsbU6UNxQqOa2j7CqvLMs2Em/kj8qfBhCuMvPmsJvGYEQ0EZs8ouAnEAzmU+SD5HXq55jI0/HCvyj/voPlwkUFeRaiGOA78O2djodgJiX5Pm0Zx/MgHqfJn4kIb4esHHE5W8v/3o7nJiR+o/pLx1n1gwPlA4wohp9x0HEQvkVC5MjzsMzgeTBEiTrwDnIQbAYLfeJYDS93ud8hcmEnQn5Ir3QCkSjvkLYlZ8h1NZyq5X0xYMKmbbYtC0Y4XpP0CvZf+btgOZ9TW6d5gND8TN5347l/oOWbSow9xhA7fPRtxkQZ4RMNcR92bseorXtNe9beq7GFQeRFOB28TN7xdsl8jca8IWd4QulsNIL95EJ1aDomeXqe/L8OaTQWyf5mTy6djUZA3uxCTXKMhPjkBGp/09RoXBaQViHNUaZGGo0O8otHyzcZyD2ycxs5vEZjUbB5tE/pbDQajUaj0Wg0Go1GYwvl/2x9FDvLuomPAAAAAElFTkSuQmCC>

[image3]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAIgAAAAXCAYAAADQigfEAAAEsElEQVR4Xu2aa6gVVRTHl2VpD5O0MqEQUzGlh5R+CCpvBVpRlIFoZYmVFKEUpBSkGdSHQHpSkVb0Lg00pcAoX0Up1YeiD0UWKAVqJZmJRkjU/3/Wnpk9yzPnrHvOmTzS/ODPvXvtPXvWnlmz99r7XpGKioqKiorSmQh9Du0NP2/NV6fcBK2BNkFvQ8Py1aUzCrodOj6yXQw9FpUTDrWvRQy3hl5wKvQitAH6DJqdr07xjN3bl5wPbYF6oNOgZdA/0LyoDbkT+go6JZQfgHZG5f+CS0V9i/ULdFHcSLrD15gBos/3BWh3vsrNSdDXomMjp0PfQw8mDQKesXv7qvEhNDkq94O2Qvuhk4NtCPQnNDVpBI6AfoLmR7ayuUz0nttFB/g8NDrXont8TRgH/Qy9CX0D/Z6vdvOo6Jhj7oB2QUeFsnfsnr5q8GIuK4yegZH9OdGvM1lq+JPlc9IWylrofWMrE84g/Aob0S2+1uNdaT1AtkHLjS2ZUZMZ1Dv2bdK8rxp9oV9DxcjIzjWdtrmh/HQocyqKWSkaYP2N3XId1McaI64UE7kF9EjzAGnX1zJpNUCYL3BMS4yd6QHtC0LZM3ZvXynnikZPzAeijTmlk3dCmZ3HJPnKCGO3zIEessbAPaLONgqghB7oLdEpkkkYg/txyV/brq9l0mqAjBf1nQEQc3awvxTKnrF7+yqEWfZf0CeSPfgkYOyN3wj2McZeD85KtxgbA5MP7UhjL+IC6EfojFDmgPnA701btOfrk6JtvPpIL3PTaoBMFL2ffaljg/31UPaM3dtXIa+KvgTuaBLek/o3Zme0c/vZDOY7TNRuDGW+bCbIJ6QtmsPdwDBjow97RDNz0glfy6LVAOGzqvdS+cJpfyWUPWP39lWX66HfoLOM/TXRi4caO6d72gcbexHMeTjdLYLWQSfmq1viEVEfpodyp3wtAwYIg7m3cKdG358xdr4n2rnMEs/YvX0dBJOUrdAEWwGeEL3YHvKsCnbODl4uEc0d7rIVTeBytxHaLPn7MamiD0lC3UlfO02rAcLZkb7zYCuG74r2haHsGbu3rxzMen+Q/BaHL/La8PtM0YvPy6prME/51NgacSH0haiTXBdvyFc35Gjob2gfdGxkZ8JK364K5XZ87W0OskEvc8MA+cManfAwc4WxXSHqB3eBxDt2T18p3PrweJ3LS8z90NXhdy4FHNjNWXXthfFgxTsTcO37TrIEk4kpp8TeBAn95K4rhrsZnk4OCuVO+FoWDBBuN+tBv2dJccL+sOjzi3dsPPzaIdkRgXfsnr5SXhZ9wEwYN0LfinbIaDozbaWzCc/2kwHMhr4U37kCt1Z0yOY2zElWQ9OMvQgG7LOSzSD8O8wB6La0hdKOr2XCZ8wZ8DhbIVkiebetCNB3zgLJrH6M6EwwI22heMbu7au2g7DTZixGX8wkaLHol/+UZF9tM5iQcp9dD/7hjVPgQFtRAJPR9dDHkh+kpVVfOw3vy+0wP8LkuXIjwGDhkpvAr5pLKHd6RbCv+0Q/6qXQlFxthmfs3r4qugjmZg23mRX/b66Rg5fLiooaTBh5Enqo/iWhosvhnx0ut8aKioqKw5N/AYq0ctRLYB6CAAAAAElFTkSuQmCC>

[image4]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAC0AAAAYCAYAAABurXSEAAACQElEQVR4Xu2WS0jUURTGvzJ74UKKMomICB/LwlUPS3pQ4E56ugi1TQ+Soo0WRQ9EIalFBdUiCBWpdkqWtDAKFAoEqWgRVCAtpEWlUEv7vs4Z5npJiUaYIf4/+MG95zAz93HuvQMkJCTkLKvpeTpAP9Ah+po2eL6dbvV2TnCO/qCDdBdd4PE8eom+8vxCj2edu3SSnogTzjw6SvviRLZohA1YZTETT+ipOJgNltPv9D3Nj3IxbbQ0DmaDq7BVzokV/FvewQa9Pk5kwFq6I+gfpV9pdRD7Z3Q7aMA/YTfETOyjq+LgNNygZ4K+DrEGXRDEMuITbOCLonjIYvqUzo0T0zBMK4P+Bo/NGrp/NeiaOOEsoT10WxQ/Qm/DzkQn3UT30+ewndMk1RfN9Ka3hR6wO/QK7MZ6EOREvcf1meIo9xttWT/9TLdEuc2wa25dFK+FPTTa9vmwSRd5bjdswCGPkZ6AbqgRusf7F+l1b4syet/b3XRnkJuCfryOPqMvaRdspofw59cvfNY1oTdBTqunlzWFvnucLvX+Adjfgznef0gPeluU0Anai/TEMkb1rZXVlws9TLfoCu+/oFWwFVVpqba1Kyla6T1v64yM0ZVIf34N3Ugvw8qs0OMZoR/6AtsBlcYjehhWf8rph3SoVULl9DS9BnsH9JCdpC0wquhHWgHbOZ2bb7CbTIvzFrZTs4LKRq/jBdgg9L9Fd7HooMfoXu9vh5XdWe9r9VNX4nFY3epAa0WXwSbUBDvcWvGEhP+aX7tHZPUExfCAAAAAAElFTkSuQmCC>

[image5]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACgAAAAYCAYAAACIhL/AAAAB6klEQVR4Xu2WTyimURTGn/yZTJmFGjENG0ZS0ljIwuYbG0WsZkqaQWxIDVMGKaXZMAuSUsifxWisLCchU9iIDYYsptmYKUXNLJQyJZ7TOZ/vdZnFSO/3Ld6nfnXuOe/b99x7z73vBwQKFOi/VESWyG9yQfZtLKxYfpo8Dr8QLX2GGsx38nnkFGo4qvpJfrlJ0zbUfK5b8EsFUAOf3AKVDF1BIcWp+ab3UIMNboFqgtY+uAU/tQg18cyTk9WqJ0ekj8R5ar5KtvAMalAOwldyAN3ScVIYeTQ6qsS/+y8mNAw1WOcWYkU/oAbT3YJHCeQjtFffkA4yR6pJO+kiq7h+mcvhGiODZIaUWP4FmYXeu93kndVvVRbU3IZbcFQGvYr2SKvlXpLvJNPGy6TU4hqyCZ3YA+hvpJF4MmnPvIZO6hXZstyVZDbr5C/05UPoASn3PuRRBnR1Tkii5eRkD1gsRv6QHBt/Q+TKek52LZab4KnFQ6TH4ntRBZn3jGW7qywOkR3yiKRCJx02+5aM4mYLya6FLHZrd5L0YKfFsoryJ0IMifqhfSj1bHJMkqDb+4U0khHod17a4gk5Jw+h5lpwD1ogxRbLD0n/hCVfIjEiJkW1UNO9pI1MkWao+TXoZOVgyMpOQFskUKCY0SVlV2CXw8AjNwAAAABJRU5ErkJggg==>

[image6]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACYAAAAYCAYAAACWTY9zAAAB0UlEQVR4Xu2WSyhFURSGl8fEI+8YMCBkoExMUJQYKKEMyFB5JCMReeRKoSjkNUNSlAEDAwMTKQxISmHC0MDEayBK/Mta+97Tnij35ij3q6/WWWuf29r77LPPJQoSJMgXRXAX3sEP+AJP4JJzkJtskTSWbxfcJJRkxa7sgtsUkKzWrF1wmwGSxmrtgtvswzcYaxfchJt5J2nuN2mD97DSLhj48fFjHLYLSidMsZMBIJyksWi7YJgjaazMLoAEeGAnA0QhPLWTTi7hK4yy8iFwBbbrdQacgauwC45rzDPn46YPrusY1lANN+GU1uM03wvnzSCbHJLV4pPfSQTJjz+T74XogUnwEWZrju+rgiMkTRr4y8FHUAXJxM2kJ2G3xjuwXmMvJSQ/ekbS2K1e89I+aI5dMzeANFiu4wznsJXkjc515LmxOnhIsskN3BiflbzKTzDRUfMLPu8GNY4haagR3nhHEMWTTC6dZHJZjtoRrIHF8NiR95tt2KBxC5yAmfDCO4LIA5s0voapGpeS73Hzm857rgMma+7HmO/pIhwl2bxhWuM9Ng0X4JDmGN74G3AMLsNIzfMJsAf79dov8uib19stmklW60/BfyZ547Ic/y8+AaGHW85yVC4CAAAAAElFTkSuQmCC>

[image7]: <data:image/png;base64,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>

[image8]: <data:image/png;base64,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>