"""
Mock AI Server for Load Testing and Chaos Engineering

This FastAPI application simulates an AI chat service with configurable chaos engineering
features to test system resilience and autoscaling behavior under various failure modes.

Features:
    - Simulated AI chat and analysis endpoints
    - Configurable latency injection (I/O bound simulation)
    - CPU stress testing (CPU bound simulation)
    - Memory leak simulation
    - Random error injection
    - Health check endpoint
    - Admin chaos control panel

Usage:
    Run with uvicorn:
        uvicorn mock_ai_server:app --host 0.0.0.0 --port 8000

    Trigger chaos scenarios:
        POST /admin/chaos/latency_spike  # Increase latency to 3-8s
        POST /admin/chaos/memory_leak    # Enable memory leak
        POST /admin/chaos/cpu_spike      # Enable CPU stress
        POST /admin/reset                # Reset to normal state

Dependencies:
    - fastapi: Web framework
    - pydantic: Request validation
    - psutil: Process memory monitoring
    - asyncio: Async I/O operations
"""

import time
import random
import asyncio
import math
from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel
import psutil
import os

app = FastAPI()

# --- SIMULATION STATE ---
# Global configuration dictionary controlling simulation behavior
SIMULATION_CONFIG = {
    "latency_min": 0.5,          # Minimum simulated latency in seconds
    "latency_max": 2.0,          # Maximum simulated latency in seconds
    "error_rate": 0.0,           # Probability of returning 503 errors (0.0 to 1.0)
    "memory_leak_active": False, # When True, allocates 1MB per request
    "cpu_stress_active": False,  # When True, makes /analyze CPU-bound instead of I/O-bound
    "memory_store": []           # Accumulates memory when memory_leak_active is True
}


class ChatRequest(BaseModel):
    """
    Request model for AI chat and analysis endpoints.
    
    Attributes:
        query (str): The user's question or prompt for the AI
        user_id (str): Unique identifier for the user making the request
        mock_mode (bool): If True, uses simplified mock responses (default: False)
    
    Example:
        {
            "query": "Summarize this email",
            "user_id": "user_12345",
            "mock_mode": true
        }
    """
    query: str
    user_id: str
    mock_mode: bool = False

@app.post("/api/v1/agent/chat")
async def chat_endpoint(request: ChatRequest, response: Response):
    """
    Simulates an AI chat endpoint with configurable latency and error injection.
    
    This endpoint demonstrates I/O-bound behavior typical of LLM API calls.
    It uses asyncio.sleep() to simulate non-blocking I/O operations.
    
    Chaos Features:
        - Random latency between configured min/max values
        - Random 503 errors based on error_rate
        - Optional memory leak (allocates 1MB per request when active)
    
    Args:
        request (ChatRequest): Chat request containing query, user_id, and mock_mode
        response (Response): FastAPI response object for setting status codes
    
    Returns:
        dict: Response containing:
            - response_text (str): Simulated AI response
            - processing_time (str): Actual processing time in seconds
            - server_memory_usage_mb (float): Current server memory usage in MB
        
        On error (503):
            - error (str): Error message indicating service unavailability
    
    Example:
        Request:
            POST /api/v1/agent/chat
            {"query": "Summarize email", "user_id": "123", "mock_mode": true}
        
        Success Response (200):
            {
                "response_text": "Simulated AI response to: Summarize email",
                "processing_time": "1.23s",
                "server_memory_usage_mb": 145.67
            }
        
        Error Response (503):
            {"error": "Service Unavailable - Overwhelmed"}
    """
    # 1. Simulate Latency (I/O Bound)
    # Randomly select a delay between configured min/max to mimic real LLM API response times
    delay = random.uniform(SIMULATION_CONFIG["latency_min"], SIMULATION_CONFIG["latency_max"])
    await asyncio.sleep(delay)

    # 2. Chaos: Random Failures
    if random.random() < SIMULATION_CONFIG["error_rate"]:
        response.status_code = 503
        return {"error": "Service Unavailable - Overwhelmed"}

    # 3. Chaos: Memory Leak
    if SIMULATION_CONFIG["memory_leak_active"]:
        SIMULATION_CONFIG["memory_store"].append("x" * 1024 * 1024) 

    return {
        "response_text": f"Simulated AI response to: {request.query}",
        "processing_time": f"{delay:.2f}s",
        "server_memory_usage_mb": psutil.Process(os.getpid()).memory_info().rss / 1024 / 1024
    }

@app.post("/api/v1/agent/analyze")
async def analyze_endpoint(request: ChatRequest):
    """
    Simulates a heavy analysis task with dual-mode operation.
    
    This endpoint can operate in two modes:
    
    1. I/O Bound Mode (default):
       - Uses asyncio.sleep() for non-blocking async operation
       - Allows the event loop to handle other requests concurrently
       - Simulates waiting for external resources (databases, APIs)
    
    2. CPU Bound Mode (when cpu_stress_active is True):
       - BLOCKS the event loop with synchronous CPU-intensive calculations
       - Continuously computes square roots to burn CPU cycles
       - Demonstrates the impact of blocking operations on async servers
       - Useful for testing autoscaler CPU-based scaling policies
    
    Args:
        request (ChatRequest): Analysis request containing query, user_id, and mock_mode
    
    Returns:
        dict: Analysis result containing:
            - status (str): Completion message
            - mode (str): Either "IO_BOUND" or "CPU_BOUND"
    
    Example:
        Request:
            POST /api/v1/agent/analyze
            {"query": "Analyze dataset", "user_id": "admin", "mock_mode": true}
        
        I/O Bound Response:
            {"status": "Analysis Complete", "mode": "IO_BOUND"}
        
        CPU Bound Response:
            {"status": "Heavy Analysis Complete", "mode": "CPU_BOUND"}
    
    Note:
        In production, CPU-bound operations should be offloaded to background
        workers or separate compute services to avoid blocking the event loop.
    """
    target_duration = SIMULATION_CONFIG["latency_min"] * 2
    
    if SIMULATION_CONFIG["cpu_stress_active"]:
        # BLOCKING OPERATION: This simulates bad code!
        # It calculates square roots in a tight loop to burn CPU cycles.
        # In an interview, this lets you talk about "Blocking the Event Loop".
        end_time = time.time() + target_duration
        while time.time() < end_time:
            _ = math.sqrt(random.randint(1, 10000)) * random.random()
        return {"status": "Heavy Analysis Complete", "mode": "CPU_BOUND"}
    else:
        # Standard async wait (I/O bound)
        await asyncio.sleep(target_duration)
        return {"status": "Analysis Complete", "mode": "IO_BOUND"}

@app.get("/health")
async def health_check():
    """
    Health check endpoint for container orchestration systems.
    
    This endpoint is designed to be used by Kubernetes liveness/readiness probes
    or similar health monitoring systems. It returns the current server status
    and configuration state.
    
    Returns:
        dict: Health status containing:
            - status (str): Always "healthy" (endpoint responding means healthy)
            - config (dict): Current SIMULATION_CONFIG state
    
    Example:
        Request:
            GET /health
        
        Response (200):
            {
                "status": "healthy",
                "config": {
                    "latency_min": 0.5,
                    "latency_max": 2.0,
                    "error_rate": 0.0,
                    "memory_leak_active": false,
                    "cpu_stress_active": false,
                    "memory_store": []
                }
            }
    
    Note:
        In production, this should check actual dependencies (database connections,
        external API availability, etc.) rather than always returning healthy.
    """
    return {"status": "healthy", "config": SIMULATION_CONFIG}

# --- CHAOS CONTROL PANEL ---
# Admin endpoints for injecting various failure modes and performance issues
# These simulate real-world production incidents for testing resilience

@app.post("/admin/chaos/latency_spike")
async def trigger_latency_spike():
    """
    Triggers a latency spike scenario for chaos testing.
    
    Increases response times to 3-8 seconds to simulate:
    - Network degradation
    - Downstream service slowdowns
    - Database query performance issues
    - LLM API slowdowns under load
    
    Use this to test:
    - Load balancer timeout configurations
    - Client retry logic
    - Circuit breaker behavior
    - User experience degradation
    
    Returns:
        dict: Confirmation message with status "LATENCY SPIKE ACTIVATED"
    
    Example:
        POST /admin/chaos/latency_spike
        Response: {"status": "LATENCY SPIKE ACTIVATED"}
    
    Note:
        Call POST /admin/reset to restore normal latency (0.5-2.0s)
    """
    SIMULATION_CONFIG["latency_min"] = 3.0
    SIMULATION_CONFIG["latency_max"] = 8.0
    return {"status": "LATENCY SPIKE ACTIVATED"}

@app.post("/admin/chaos/memory_leak")
async def trigger_memory_leak():
    """
    Triggers a memory leak scenario for resource management testing.
    
    Once activated, each /chat request allocates 1MB of memory that is never freed.
    This simulates common memory leak patterns:
    - Unbounded caches
    - Unclosed database connections
    - Growing session stores
    - Event listener accumulation
    
    Use this to test:
    - Container memory limits (OOMKilled behavior)
    - Kubernetes memory-based autoscaling
    - Memory monitoring and alerting
    - Pod eviction policies
    
    Returns:
        dict: Confirmation message with status "MEMORY LEAK ACTIVATED"
    
    Example:
        POST /admin/chaos/memory_leak
        Response: {"status": "MEMORY LEAK ACTIVATED"}
    
    Warning:
        This will eventually crash the server when it runs out of memory.
        Monitor server_memory_usage_mb in /chat responses.
        Call POST /admin/reset to stop the leak and free memory.
    """
    SIMULATION_CONFIG["memory_leak_active"] = True
    return {"status": "MEMORY LEAK ACTIVATED"}

@app.post("/admin/chaos/cpu_spike")
async def trigger_cpu_spike():
    """
    Triggers CPU stress testing by making /analyze CPU-bound.
    
    When activated, the /analyze endpoint switches from async I/O operations
    to synchronous CPU-intensive calculations. This blocks the event loop
    and demonstrates the impact of CPU-bound work on async servers.
    
    This simulates:
    - Heavy data processing (analytics, ML inference)
    - Complex computations
    - Inefficient algorithms
    - Blocking synchronous code in async context
    
    Use this to test:
    - CPU-based autoscaling policies
    - Request timeout behavior under CPU load
    - Concurrent request handling degradation
    - CPU throttling in containerized environments
    
    Returns:
        dict: Confirmation message with status "CPU STRESS ACTIVATED"
    
    Example:
        POST /admin/chaos/cpu_spike
        Response: {"status": "CPU STRESS ACTIVATED"}
    
    Warning:
        This will severely impact server throughput by blocking the event loop.
        Each /analyze request will consume ~100% of one CPU core.
        Call POST /admin/reset to restore async I/O behavior.
    
    Interview Insight:
        This demonstrates understanding of the difference between I/O-bound
        and CPU-bound operations in async Python and their performance implications.
    """
    SIMULATION_CONFIG["cpu_stress_active"] = True
    return {"status": "CPU STRESS ACTIVATED"}

@app.post("/admin/reset")
async def reset_simulation():
    """
    Resets all chaos configurations to default healthy state.
    
    This endpoint restores the server to normal operating parameters:
    - Latency: 0.5-2.0 seconds (typical LLM response times)
    - Error rate: 0% (no random failures)
    - Memory leak: Disabled and memory freed
    - CPU stress: Disabled (async I/O mode)
    
    Use this to:
    - Return to baseline after chaos experiments
    - Clean up before starting new test scenarios
    - Recover from cascading failures during testing
    
    Returns:
        dict: Confirmation message with status "SYSTEM NORMALIZED"
    
    Example:
        POST /admin/reset
        Response: {"status": "SYSTEM NORMALIZED"}
    
    Note:
        This immediately takes effect for all subsequent requests.
        In-flight requests will continue with their original configuration.
    """
    SIMULATION_CONFIG["latency_min"] = 0.5
    SIMULATION_CONFIG["latency_max"] = 2.0
    SIMULATION_CONFIG["error_rate"] = 0.0
    SIMULATION_CONFIG["memory_leak_active"] = False
    SIMULATION_CONFIG["cpu_stress_active"] = False
    SIMULATION_CONFIG["memory_store"] = []  # Free leaked memory
    return {"status": "SYSTEM NORMALIZED"}
