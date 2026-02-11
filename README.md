# Production Deployment

## Overview

This repository contains the production deployment scripts and configurations for the following projects.

* **[simulated-scale](simulated-scale)**: A load testing and chaos engineering toolkit for AI services, consisting of a configurable FastAPI mock server that simulates various failure modes (latency spikes, memory leaks, CPU stress) and a Locust-based load test suite that simulates realistic user traffic patterns with automated staged ramp-up testing.

* **[healthcare-agent-gke-autopilot](healthcare-agent-gke-autopilot)**: A production-ready reference architecture for deploying a Parlant-based AI agent on GKE Autopilot, integrated with Vertex AI (or a mock LLM), MongoDB Atlas, and a Next.js frontend. It emphasizes secure, scalable, and observable operations using Workload Identity Federation, Cloud Armor, least-privilege IAM, and OpenTelemetry with Cloud Trace and Managed Prometheus. A built-in Simulated Scale framework (Mock LLM + Locust) enables deterministic infrastructure stress testing—validating NAT ports and DB limits—without incurring LLM inference costs.