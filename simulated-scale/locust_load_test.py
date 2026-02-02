"""
Locust Load Testing Suite for Mock AI Server

This module implements a comprehensive load testing strategy using Locust to simulate
realistic user traffic patterns against the mock AI server. It includes:

- Multi-weighted task scenarios (chat, analysis, health checks)
- Automated staged ramp-up for load progression
- SLA violation detection and custom failure conditions
- Request analytics and monitoring

Test Scenarios:
    1. Chat Interaction (Weight: 3) - I/O-bound requests simulating typical user queries
    2. Heavy Analysis (Weight: 1) - CPU-intensive requests for stress testing
    3. Health Check (Weight: 1) - Simulates Kubernetes liveness probes with strict timeouts

Load Profile (StagedRampUp):
    - Stage 1 (0-30s): Warmup with 10 users @ 5/s spawn rate
    - Stage 2 (30-60s): Load testing with 50 users @ 10/s spawn rate
    - Stage 3 (60-90s): Stress testing with 100 users @ 20/s spawn rate
    - Stage 4 (90-120s): Cooldown to 10 users @ 5/s spawn rate

Usage:
    # Run with default staged ramp-up:
    locust -f locust_load_test.py --host http://localhost:8000 --headless

    # Run with custom parameters:
    locust -f locust_load_test.py --host http://localhost:8000 -u 100 -r 10

    # Run with web UI for real-time monitoring:
    locust -f locust_load_test.py --host http://localhost:8000

Configuration:
    MOCK_LLM_RESPONSE (bool): When True, server uses simplified mock responses

Dependencies:
    - locust: Load testing framework
"""

import time
import random
from locust import FastHttpUser, task, between, events, LoadTestShape

# --- CONFIGURATION ---
# Controls whether the server returns simplified mock responses or simulates real LLM processing
MOCK_LLM_RESPONSE = True 

class AIUser(FastHttpUser):
    """
    Simulates a single AI application user making requests to the mock server.
    
    This class uses FastHttpUser for better performance through connection pooling
    and HTTP/1.1 keep-alive. Each user executes weighted tasks randomly with
    configured wait times between requests.
    
    Attributes:
        wait_time: Random delay between 1-5 seconds between consecutive requests
        headers (dict): HTTP headers including Authorization and Content-Type
    
    Task Weights:
        - chat_interaction: 3x (60% of traffic) - Standard user queries
        - heavy_analysis_request: 1x (20% of traffic) - Heavy compute tasks
        - health_check: 1x (20% of traffic) - Liveness probes
    
    Note:
        FastHttpUser uses FastHttpSession which handles connection pooling
        automatically but doesn't have a headers attribute, so we store
        headers as an instance variable.
    """
    wait_time = between(1, 5)  # Random wait between requests (realistic user behavior)

    def on_start(self):
        """
        Called once when a new user starts (before any tasks run).
        
        Initializes headers with authorization token and content type.
        These headers are used for all subsequent requests by this user.
        
        Note:
            FastHttpSession doesn't have a headers attribute, so we store
            headers as an instance variable and pass them to each request.
        """
        # FastHttpSession doesn't have a headers attribute
        # Store headers as instance variable instead
        self.headers = {
            "Authorization": "Bearer production-sim-token",
            "Content-Type": "application/json"
        }

    @task(3)
    def chat_interaction(self):
        """
        Simulates a standard chat interaction (I/O-bound operation).
        
        This is the most common user action, weighted 3x to represent 60% of traffic.
        It simulates users asking questions, requesting summaries, or general chat.
        
        Task Weight: 3 (executed 3x more often than weight-1 tasks)
        
        Request Details:
            - Endpoint: POST /api/v1/agent/chat
            - Payload: Random user query with mock mode enabled
            - User ID: Random 4-digit number (simulates different users)
        
        Success Criteria:
            - 200: Success (normal response)
        
        Failure Conditions:
            - 503: Service Unavailable (server overwhelmed)
            - 504: Gateway Timeout (upstream timeout)
            - Other: Any other non-200 status code
        
        Example Payload:
            {
                "query": "Summarize email",
                "user_id": "1234",
                "mock_mode": true
            }
        """
        payload = {
            "query": "Summarize email",
            "user_id": str(random.randint(1000, 9999)),
            "mock_mode": MOCK_LLM_RESPONSE
        }
        with self.client.post("/api/v1/agent/chat", json=payload, headers=self.headers, catch_response=True) as response:
            if response.status_code == 200:
                response.success()
            elif response.status_code == 503:
                response.failure("503: Upstream Service Unavailable")
            elif response.status_code == 504:
                response.failure("504: Gateway Timeout")
            else:
                response.failure(f"Error {response.status_code}")

    @task(1)
    def heavy_analysis_request(self):
        """
        Simulates a heavy analysis task (potentially CPU-bound).
        
        This task tests the server's ability to handle compute-intensive requests
        that may take longer and consume more resources. When cpu_stress_active
        is enabled on the server, this becomes a true CPU stress test.
        
        Task Weight: 1 (20% of traffic)
        
        Request Details:
            - Endpoint: POST /api/v1/agent/analyze
            - Payload: Analysis request with mock mode enabled
            - User ID: "admin" (typically used by power users)
        
        SLA Monitoring:
            Response times > 2.0 seconds are marked as SLA violations,
            even if the server returns 200 OK. This helps identify
            performance degradation on Locust's dashboard.
        
        Success Criteria:
            - 200 status AND response time <= 2.0s
        
        Failure Conditions:
            - Response time > 2.0s (SLA violation)
            - Any non-200 status code
        
        Use Case:
            Tests autoscaling triggers based on CPU utilization and
            response time degradation under heavy compute load.
        
        Example Payload:
            {
                "query": "Analyze dataset",
                "user_id": "admin",
                "mock_mode": true
            }
        """
        start_time = time.time()
        payload = {
            "query": "Analyze dataset",
            "user_id": "admin",
            "mock_mode": MOCK_LLM_RESPONSE
        }
        with self.client.post("/api/v1/agent/analyze", json=payload, headers=self.headers, catch_response=True) as resp:
            elapsed_time = time.time() - start_time
            if elapsed_time > 2.0:
                 # Mark as failure if it's too slow, even if 200 OK
                 # This helps visualize "SLOWNESS" on the graph
                 resp.failure("SLA Violation: > 2s Response")


    @task(1)
    def health_check(self):
        """
        Simulates a GKE Liveness Probe.
        In production, if this takes > 1s, the pod is marked unhealthy.
        """
        start_time = time.time()
        with self.client.get("/health", headers=self.headers, catch_response=True) as response:
            elapsed_time = time.time() - start_time
            # We enforce a strict 1-second 'Production' timeout here
            if elapsed_time > 1.0:
                response.failure(f"Health Check Timeout: > 1s (Pod would be restarted)")
            elif response.status_code != 200:
                response.failure("Health Check Failed: Non-200 Status")
            else:
                response.success()        

# --- AUTOMATED RAMPING STRATEGY ---

class StagedRampUp(LoadTestShape):
    """
    Automated load testing strategy with four distinct stages.
    
    This custom LoadTestShape eliminates the need for manual user ramping
    by automatically controlling the number of users and spawn rate over time.
    It simulates a realistic production traffic pattern:
    
    Stage Progression:
        1. Warmup (0-30s):
           - Users: 10
           - Spawn Rate: 5/s
           - Purpose: Warm up server caches, JIT compilation, connection pools
        
        2. Load Testing (30-60s):
           - Users: 50
           - Spawn Rate: 10/s
           - Purpose: Test normal production load levels
        
        3. Stress Testing (60-90s):
           - Users: 100
           - Spawn Rate: 20/s
           - Purpose: Push system beyond normal capacity to find breaking points
        
        4. Cooldown (90-120s):
           - Users: 10
           - Spawn Rate: 5/s
           - Purpose: Observe recovery behavior and resource cleanup
    
    Usage:
        This shape is automatically used when running:
            locust -f locust_load_test.py --host http://localhost:8000
    
    Returns:
        tuple: (user_count, spawn_rate) for current time, or None to stop
    
    Attributes:
        stages (list): List of stage configurations with duration, users, and spawn_rate
    
    Interview Insight:
        This demonstrates understanding of proper load testing methodology:
        gradual ramp-up, sustained load, stress testing, and graceful degradation.
    """
    stages = [
        {"duration": 30,  "users": 10,  "spawn_rate": 5},   # Warmup
        {"duration": 60,  "users": 50,  "spawn_rate": 10},  # Load
        {"duration": 90,  "users": 100, "spawn_rate": 20},  # Stress
        {"duration": 120, "users": 10,  "spawn_rate": 5},   # Cooldown
    ]

    def tick(self):
        """
        Called repeatedly during the test to determine current user count.
        
        This method is invoked approximately once per second by Locust to
        determine how many users should be active at the current time.
        
        Returns:
            tuple: (user_count, spawn_rate) if test should continue
            None: If test should stop (after all stages complete)
        
        Algorithm:
            Iterates through stages and returns the configuration for the
            first stage whose duration hasn't been exceeded yet.
        """
        run_time = self.get_run_time()  # Seconds since test started
        for stage in self.stages:
            if run_time < stage["duration"]:
                return (stage["users"], stage["spawn_rate"])
        return None  # Stop test after all stages complete

# --- ANALYTICS ---
# Event listeners for real-time monitoring and alerting

@events.request.add_listener
def on_request(request_type, name, response_time, response_length, exception, **kwargs):
    """
    Event listener for real-time request analytics and alerting.
    
    This function is called after EVERY request completes, allowing for
    custom logging, metrics collection, and alerting based on performance.
    
    Args:
        request_type (str): HTTP method (GET, POST, etc.)
        name (str): Request name/URL path
        response_time (float): Response time in milliseconds
        response_length (int): Response body size in bytes
        exception (Exception): Exception if request failed, None otherwise
        **kwargs: Additional request metadata
    
    Current Functionality:
        Logs requests that exceed 4000ms (4 seconds) as critical slowness.
        This helps identify specific slow requests during load tests.
    
    Use Cases:
        - Real-time alerting for SLA violations
        - Custom metrics export to monitoring systems
        - Request-level debugging during load tests
        - Identifying outliers and tail latencies
    
    Example Output:
        [CRITICAL SLOWNESS] /api/v1/agent/analyze took 4523ms
    
    Note:
        In production load tests, you might extend this to:
        - Send metrics to Prometheus/Datadog
        - Trigger alerts in PagerDuty/Slack
        - Log to structured logging systems
    """
    if response_time > 4000:  # 4 seconds threshold
        print(f"[CRITICAL SLOWNESS] {name} took {response_time}ms")
