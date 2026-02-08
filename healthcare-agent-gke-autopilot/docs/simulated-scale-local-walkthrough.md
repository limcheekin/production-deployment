# Local Load Testing Walkthrough

This document guides you through running load tests locally for the Parlant healthcare agent using Docker Compose and Locust.

## Prerequisites

- Docker and Docker Compose installed.
- `gcloud` CLI installed and authenticated (for image registry access if needed, though local build is default).
- Python 3.11+ (recommended for local script analysis).

## Architecture

The local load test spins up the following services via `load_testing/docker-compose.yaml`:
- **Parlant**: The agent application (built from source).
- **Mock LLM**: A FastAPI service simulating Gemini Pro/Flash (built from `load_testing/`).
- **MongoDB**: Database for Parlant.
- **Locust**: Load testing tool.

## Setup & configuration

1. **Environment Variables**:
   The `load_testing/docker-compose.yaml` sets default values. Key variables:
   - `JWT_SECRET_KEY`: Used for generating test tokens. Default: `local-secret-key`.
   - `MOCK_MIN_LATENCY` / `MOCK_MAX_LATENCY`: value control mock LLM thinking time.

2. **Auth Policy**:
   `auth.py` has been updated to include a **load testing override** that allows high-rate traffic and validates JWT tokens signed with `JWT_SECRET_KEY`.

## Running the Test

To run the baseline load test (5 users, 5 minutes):

```bash
./load_testing/run-scale-test.sh local
```

This script will:
1. Build Docker images for Parlant and Mock LLM.
2. Start the services using Docker Compose.
3. Wait for services to be healthy.
4. Execute the Locust baseline test.
5. Generate HTML reports in `load_testing/results/`.

## Verification Results

### Successes
- **Infrastructure**: All containers start and communicate correctly.
- **Authentication**: `GET /agents` and `POST /sessions` (Session Creation) work with valid JWTs.
- **Load Test Execution**:
  - Baseline test (2 users, 1 minute) completed successfully with **0 failures**.
  - Average response time for `Full_Turn_Quick_Chat` was ~370ms.
  - Dynamic schema generation in `mock_llm_server.py` correctly handles diverse schemas from Parlant (e.g., `JourneyNextStepSelectionSchema`, `CannedResponseDraftSchema`).

### Design Decisions
- **Mock LLM Strategy**: We moved from strict keyword-based heuristics to a **dynamic schema-based generation** approach. If a request provides a `responseSchema`, the mock server recursively generates valid JSON (handling objects, arrays, enums, etc.) to ensure Parlant's Pydantic validation passes. This makes the test robust against future schema changes in Parlant.

## Troubleshooting

### Authentication Errors (403)
If you see 403 Forbidden errors:
- Ensure `auth.py` contains the `check_permission` override.
- Check that `locust_load_test.py` generates tokens using the matching `JWT_SECRET_KEY`.

### Schema Validation Errors
If Parlant logs schema validation errors from Gemini:
- The Mock LLM (`mock_llm_server.py`) now dynamically generates responses based on the requested schema.
- Check `mock-llm` logs to see if the schema is being correctly identified (`DEBUG: Generating dynamic response for schema: ...`).
- If complex logic is required (e.g., specific values for a test case), adds a specific override in `mock_llm_server.py` before the fallback dynamic generation.

### Viewing Logs
To debug issues during the test:

```bash
docker logs -f load_testing-parlant-1
docker logs -f load_testing-mock-llm-1
```
