"""
Locust Load Test for Parlant Healthcare Agent

This script implements the asynchronous polling pattern required to load test
a Parlant agent. Unlike traditional HTTP load testing, agentic systems require
measuring the full "turn latency" - from message send to agent response.

Usage:
    locust -f locust_load_test.py --host http://YOUR_INGRESS_IP:8800

Configuration via environment variables:
    - PARLANT_AGENT_ID: Agent ID to test against (default: auto-detect first agent)
    - POLL_TIMEOUT: Max time to wait for agent response in seconds (default: 60)
    - POLL_WAIT_FOR_DATA: Long-poll timeout in seconds (default: 10)
"""

import os
import time
from locust import HttpUser, task, events, between


# Configuration
POLL_TIMEOUT = int(os.environ.get("POLL_TIMEOUT", "60"))
POLL_WAIT_FOR_DATA = int(os.environ.get("POLL_WAIT_FOR_DATA", "10"))

# Test messages for different user types
QUICK_MESSAGES = [
    "Hello",
    "What are your office hours?",
    "Thank you",
]

COMPLEX_MESSAGES = [
    "I would like to schedule an appointment for next week",
    "Can you check my lab results and explain what they mean?",
    "I need to see a specialist for my back pain, what are my options?",
]


class ParlantUser(HttpUser):
    """
    Simulated Parlant user that measures full conversation turn latency.
    
    Implements the polling pattern from the simulated-scale-guide:
    1. Create session
    2. Send message
    3. Poll for agent response
    4. Record total turn latency
    """
    
    # Random wait between tasks (1-3 seconds)
    wait_time = between(1, 3)
    
    def on_start(self):
        """Initialize user session on test start."""
        self.agent_id = os.environ.get("PARLANT_AGENT_ID")
        self.session_id = None
        self.last_offset = 0
        
        # Get agent ID if not specified
        if not self.agent_id:
            self._discover_agent()
        
        # Create a session for this user
        self._create_session()
    
    def _discover_agent(self):
        """Discover the first available agent."""
        with self.client.get("/agents", catch_response=True) as response:
            if response.status_code == 200:
                agents = response.json()
                if agents:
                    self.agent_id = agents[0]["id"]
                    response.success()
                else:
                    response.failure("No agents found")
            else:
                response.failure(f"Failed to list agents: {response.status_code}")
    
    def _create_session(self):
        """Create a new conversation session."""
        if not self.agent_id:
            return
            
        with self.client.post(
            "/sessions",
            json={"agent_id": self.agent_id},
            catch_response=True,
            name="/sessions (create)"
        ) as response:
            if response.status_code == 200:
                data = response.json()
                self.session_id = data.get("id")
                self.last_offset = 0
                response.success()
            else:
                response.failure(f"Failed to create session: {response.status_code}")
    
    def _poll_for_response(self, start_time: float) -> bool:
        """
        Poll for agent response using long-polling.
        
        Returns True if agent response received, False on timeout.
        """
        deadline = start_time + POLL_TIMEOUT
        
        while time.time() < deadline:
            with self.client.get(
                f"/sessions/{self.session_id}/events",
                params={
                    "min_offset": self.last_offset,
                    "wait_for_data": POLL_WAIT_FOR_DATA
                },
                catch_response=True,
                name="/sessions/{id}/events (poll)"
            ) as response:
                if response.status_code != 200:
                    response.failure(f"Polling failed: {response.status_code}")
                    return False
                
                event_list = response.json()
                
                if not event_list:
                    # Long poll timed out, retry
                    response.success()
                    continue
                
                # Update offset to avoid re-fetching
                self.last_offset = max(e.get("offset", 0) for e in event_list) + 1
                
                # Check for agent response
                agent_replied = any(
                    e.get("source") == "ai_agent" and e.get("kind") == "message"
                    for e in event_list
                )
                
                response.success()
                
                if agent_replied:
                    return True
        
        return False
    
    @task(3)
    def quick_chat(self):
        """
        Quick chat interaction (high frequency, short messages).
        Simulates the "Chatter" user type.
        """
        if not self.session_id:
            self._create_session()
            if not self.session_id:
                return
        
        import random
        message = random.choice(QUICK_MESSAGES)
        self._send_and_wait(message, "Quick_Chat")
    
    @task(1)
    def complex_query(self):
        """
        Complex query that triggers tool calls.
        Simulates the "Thinker" user type.
        """
        if not self.session_id:
            self._create_session()
            if not self.session_id:
                return
        
        import random
        message = random.choice(COMPLEX_MESSAGES)
        self._send_and_wait(message, "Complex_Query")
    
    def _send_and_wait(self, message: str, metric_name: str):
        """Send a message and wait for agent response, recording full turn latency."""
        start_time = time.time()
        
        # Send user message
        with self.client.post(
            f"/sessions/{self.session_id}/events",
            json={
                "kind": "message",
                "source": "customer",
                "message": message
            },
            catch_response=True,
            name="/sessions/{id}/events (send)"
        ) as response:
            if response.status_code != 200:
                response.failure(f"Failed to send message: {response.status_code}")
                return
            response.success()
        
        # Poll for agent response
        success = self._poll_for_response(start_time)
        
        # Record full turn latency
        total_duration_ms = (time.time() - start_time) * 1000
        
        events.request.fire(
            request_type="Conversation",
            name=f"Full_Turn_{metric_name}",
            response_time=total_duration_ms,
            response_length=0,
            exception=None if success else Exception("Agent response timeout"),
            context={}
        )


class IdlerUser(HttpUser):
    """
    Idler user that creates a session and occasionally sends a message.
    Tests session state management and idle connection handling.
    """
    
    # Long wait between tasks (30-60 seconds)
    wait_time = between(30, 60)
    
    def on_start(self):
        """Create a session that will be mostly idle."""
        self.agent_id = os.environ.get("PARLANT_AGENT_ID")
        self.session_id = None
        self.last_offset = 0
        
        # Discover agent
        with self.client.get("/agents", catch_response=True) as response:
            if response.status_code == 200:
                agents = response.json()
                if agents:
                    self.agent_id = agents[0]["id"]
                    response.success()
        
        # Create session
        if self.agent_id:
            with self.client.post(
                "/sessions",
                json={"agent_id": self.agent_id},
                catch_response=True,
                name="/sessions (create idle)"
            ) as response:
                if response.status_code == 200:
                    self.session_id = response.json().get("id")
                    response.success()
    
    @task
    def idle_ping(self):
        """Occasionally send a message to keep session alive."""
        if not self.session_id:
            return
        
        with self.client.post(
            f"/sessions/{self.session_id}/events",
            json={
                "kind": "message",
                "source": "customer",
                "message": "Hello"
            },
            catch_response=True,
            name="/sessions/{id}/events (idle ping)"
        ) as response:
            if response.status_code == 200:
                response.success()
