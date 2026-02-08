# Local Scale Test Implementation Plan

The goal is to enable running the scale test locally to facilitate easier debugging and faster iteration cycles. This will be achieved by orchestrating the necessary services (Parlant, Mock LLM, MongoDB) using Docker Compose and updating the `run-scale-test.sh` script to support a local execution mode.

## User Review Required

> [!IMPORTANT]
> This plan introduces a `docker-compose.yaml` file in the `load_testing` directory. It assumes you have Docker and Docker Compose installed on your local machine.
> The local test will use the generic `Dockerfile` for Parlant instead of `Dockerfile-GKE-Autopilot` to avoid potential permission issues with non-root users in a local context, unless you specifically require testing the production container constraints.

## Proposed Changes

### [load_testing]

#### [NEW] [docker-compose.yaml](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/docker-compose.yaml)
- Defines services:
    - `mongodb`: Standard MongoDB image.
    - `mock-llm`: Builds from `load_testing` directory.
    - `parlant`: Builds from root directory, configured to use `mock-llm` and `mongodb`.
    - `parlant`: Builds from root directory, configured to use `mock-llm` and `mongodb`.
    - `locust`: Runs Locust master/worker or standalone, mounting the load test script.
    
#### [MODIFY] [docker-compose.yaml](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/docker-compose.yaml)
- Updated to use `USE_VERTEX_AI=true`.
- Removed `GEMINI_API_KEY`.
- Set `VERTEX_AI_API_ENDPOINT=mock-llm:8000`.

#### [MODIFY] [main.py](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/main.py)
- Added monkey-patch to redirect Vertex AI calls (using `google.genai` and `httpx`) to `mock-llm` when running locally with `VERTEX_AI_API_ENDPOINT` containing "mock".
- Patches `google.auth.default` to use mock credentials.
- Patches `httpx.AsyncClient.request` and `httpx.Client.request` to rewrite URLs and schemes.

#### [MODIFY] [run-scale-test.sh](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/load_testing/run-scale-test.sh)
- Add a `local` command/mode.
- When `local` is selected:
    - Checks for Docker availability.
    - Runs `docker-compose up -d --build`.
    - Waits for services to be healthy.
    - Executes the Locust test against localhost.
    - Tears down services after the test (optional flag).

## Verification Plan

### Automated Tests
- Run `./run-scale-test.sh local` and verify that:
    - Docker containers start up. [PASS]
    - Parlant connects to Mongo and Mock LLM. [PASS]
    - Locust runs the load test and generates results. [PASS]
    - The mock LLM receives requests (check logs). [PASS]

### Manual Verification
- Inspect `docker-compose logs` to ensure no errors during startup. [PASS]
- Access the Locust web UI (if exposed) at http://localhost:8089 to see real-time stats. [PASS]

## Known Issues
- `ParlantUser` scenarios fail with `Session not found`. `IdlerUser` scenarios pass. This suggests a potential race condition or consistency issue in Parlant's session handling under load, or a mock LLM response issue for specific prompts.

