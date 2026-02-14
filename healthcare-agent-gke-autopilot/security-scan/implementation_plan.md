# Trivy Security Scanning GitHub Workflow

A comprehensive GitHub Actions workflow to detect vulnerabilities, misconfigurations, and secrets across the entire healthcare-agent-gke-autopilot codebase using [aquasecurity/trivy-action](https://github.com/aquasecurity/trivy-action).

## Codebase Analysis — Scannable Assets

| Asset Type | Paths | Trivy Scan Mode |
|---|---|---|
| Python deps | `backend/requirements.txt` | `fs` (vuln) |
| Node.js deps | `frontend/package-lock.json` | `fs` (vuln) |
| Dockerfiles (4) | `backend/Dockerfile`, `backend/Dockerfile-GKE-Autopilot`, `frontend/Dockerfile`, `backend/load_testing/Dockerfile` | `image` (vuln) |
| K8s YAMLs (static) | `backend/load_testing/locust-deployment.yaml`, `mock-llm-deployment.yaml`, `hpa.yaml` | `config` (misconfig) |
| Docker Compose | `backend/load_testing/docker-compose.yaml` | `config` (misconfig) |
| Dockerfiles (IaC) | All 4 Dockerfiles | `config` (misconfig) |
| Source code & config | `backend/*.sh`, `backend/*.py`, `frontend/src/`, `.env*` | `fs` (secret) |

> [!NOTE]
> The K8s manifests in `backend/setup.sh` are generated at runtime via heredoc with shell variable substitution (`$IMAGE_PATH`, `$KSA_NAME`, etc.). These are **not** static files and will not be scanned by Trivy's IaC scanner. Only the static YAML files in `backend/load_testing/` are scannable.

## User Review Required

> [!IMPORTANT]
> **Frontend Docker image build in CI**: The frontend's `env.mjs` enforces **required build-time env vars** (`NEXT_PUBLIC_PARLANT_API_URL` must be a valid URL, `NEXT_PUBLIC_AGENT_ID` must be non-empty) via Zod validation at `next build` time. Additionally, the Dockerfile copies from `.next/standalone` but `next.config.ts` does not set `output: 'standalone'`.
>
> **Approach**: The workflow will pass placeholder env vars (`NEXT_PUBLIC_PARLANT_API_URL=http://localhost:8800`, `NEXT_PUBLIC_AGENT_ID=placeholder`) during the Docker build step using `--build-arg`. However, the Dockerfile must accept these via `ARG`/`ENV` for this to work. Since modifying the Dockerfile is out of scope for this workflow, the **frontend image scan may fail**. If it does, the matrix `continue-on-error` will allow other scans to complete.

## Proposed Changes

### [NEW] [security-scan.yml](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/.github/workflows/security-scan.yml)

A single workflow file with **5 parallel jobs**, pinned to `aquasecurity/trivy-action@0.33.1`.

**Triggers**: pushes to `main`, pull requests to `main`, weekly schedule (Monday 06:00 UTC).

**Permissions** (at workflow level):
- `contents: read` — checkout
- `security-events: write` — SARIF upload to Security tab
- `actions: read` — required by `github/codeql-action/upload-sarif@v4` for private repos

---

#### Job 1: `vulnerability-scan` — Filesystem Dependency Scanning
- **scan-type**: `fs` | **scanners**: `vuln`
- **Targets**: Full repo (Trivy auto-detects `requirements.txt`, `package-lock.json`)
- **Severity**: CRITICAL, HIGH | **ignore-unfixed**: true
- **exit-code**: `1` (fail build on findings)
- **Output**: SARIF → GitHub Security tab (category: `trivy-vulnerability-scan`) + table to job log
- Two Trivy steps: one for SARIF output, one for human-readable table

#### Job 2: `docker-image-scan` — Container Image Vulnerability Scanning
- **Matrix strategy** builds and scans all 4 Dockerfiles:

  | Matrix key | Dockerfile | Build context |
  |---|---|---|
  | `backend` | `backend/Dockerfile` | `backend/` |
  | `backend-gke` | `backend/Dockerfile-GKE-Autopilot` | `backend/` |
  | `frontend` | `frontend/Dockerfile` | `frontend/` |
  | `load-testing` | `backend/load_testing/Dockerfile` | `backend/load_testing/` |

- **scan-type**: `image` | **scanners**: `vuln` | **Severity**: CRITICAL, HIGH
- **exit-code**: `1` | **ignore-unfixed**: true
- **Output**: SARIF per image (category: `trivy-image-{name}`)
- `continue-on-error: true` on the frontend matrix entry (may fail due to env var issues)

#### Job 3: `iac-misconfiguration-scan` — Infrastructure as Code Scanning
- **scan-type**: `config` | **scanners**: `misconfig`
- **Targets**: Full repo (auto-detects Dockerfiles, K8s YAML, docker-compose)
- **Severity**: CRITICAL, HIGH, MEDIUM
- **exit-code**: `1`
- **Output**: SARIF → GitHub Security tab (category: `trivy-iac-scan`)

#### Job 4: `secret-scan` — Hardcoded Secret Detection
- **scan-type**: `fs` | **scanners**: `secret`
- **exit-code**: `1` (hard fail — leaked secrets are always critical)
- **Output**: SARIF → GitHub Security tab (category: `trivy-secret-scan`)

#### Job 5: `license-scan` — Dependency License Compliance
- **scan-type**: `fs` | **scanners**: `license`
- **exit-code**: `0` (informational, non-blocking)
- **Output**: Table summary to job log only (no SARIF)

---

### Design Decisions

1. **SARIF uploads with unique `category`** per scan type → prevents GitHub from overwriting results across jobs (e.g., `trivy-vulnerability-scan` vs `trivy-image-backend`)
2. **`if: always()`** on all SARIF upload steps → ensures results are uploaded even if Trivy returns non-zero exit code
3. **Weekly scheduled scan** catches newly disclosed CVEs in unchanged dependencies
4. **Matrix strategy for Docker images** with precise build contexts → avoids code duplication
5. **Caching enabled** (trivy-action default) → DB is cached via `actions/cache` for faster subsequent runs
6. **`ignore-unfixed: true`** on vulnerability scans → reduces noise from CVEs without available patches
7. **`hide-progress: true`** on all scans → cleaner CI logs
8. **Pinned action version** (`@0.33.1`) → reproducible builds, no surprise breakages
9. **`timeout: '10m0s'`** for image scans → large image scans may exceed the default 5m

## Verification Plan

### Automated Tests
```bash
# Validate YAML syntax
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/security-scan.yml'))"
```

### Manual Verification
1. Push the workflow to a branch and open a PR — verify all 5 jobs trigger
2. Check **Security → Code scanning alerts** tab for SARIF results from each scan category
3. Verify matrix fan-out produces 4 separate image scan jobs
4. Confirm that a `CRITICAL` vulnerability correctly fails the build (exit-code 1)
