# Trivy Security Scanning Walkthrough

This document outlines the implementation of the comprehensive Trivy security scanning GitHub Actions workflow for the healthcare-agent-gke-autopilot project.

## Workflow Overview

The `.github/workflows/security-scan.yml` defines a robust security pipeline with **5 parallel jobs**:

1.  **Dependency Vulnerabilities (`fs`)**: Scans `requirements.txt` (Python) and `package-lock.json` (Node.js) for known CVEs.
2.  **Container Image Analysis (`image`)**: Builds and scans all 4 Docker images (`backend`, `backend-gke`, `frontend`, `load-testing`) for OS and application vulnerabilities using a matrix strategy.
3.  **IaC Misconfigurations (`config`)**: Scans Dockerfiles, Kubernetes YAMLs, and Docker Compose files for security best practice violations.
4.  **Secret Detection (`fs`)**: Detects hardcoded credentials, API keys, and tokens in the entire codebase.
5.  **License Compliance (`fs`)**: Checks dependencies for copyleft or restricted licenses (informational).

## Key Implementation Details

-   **Trigger**: Pushes to `main`, Pull Requests to `main`, and Weekly Schedule (Monday 06:00 UTC).
-   **Output**: All security-relevant scans (Jobs 1-4) upload **SARIF** reports to the GitHub **Security -> Code scanning alerts** tab.
-   **Failure Policy**: Jobs fail on `CRITICAL` or `HIGH` severity findings (exit-code 1). License scan is non-blocking (exit-code 0).
-   **Frontend CI Fix**: To enable the frontend Docker image to build successfully in CI for scanning, we:
    -   Added `output: 'standalone'` to `frontend/next.config.ts`.
    -   Added `ARG` and `ENV` instructions to `frontend/Dockerfile` for required build-time variables (`NEXT_PUBLIC_PARLANT_API_URL`, `NEXT_PUBLIC_AGENT_ID`).

## Verification Steps

### 1. Trigger the Workflow

Push the changes to a new branch and open a Pull Request, or push directly to `main` (if allowed).

```bash
git add .
git commit -m "feat: add comprehensive Trivy security scanning workflow"
git push origin your-branch-name
```

### 2. Check GitHub Actions

Go to the **Actions** tab in your GitHub repository. You should see a workflow run named **"Security Scan (Trivy)"**.

### 3. Review Security Alerts

Once the workflow completes, go to the **Security** tab -> **Code scanning alerts**. You will see vulnerabilities categorized by:
-   `trivy-vulnerability-scan`
-   `trivy-image-backend`
-   `trivy-image-frontend`
-   `trivy-iac-scan`
-   `trivy-secret-scan`

### 4. Scheduled Scans

Verify that the workflow file contains the cron schedule:
```yaml
schedule:
  - cron: '0 6 * * 1'
```
This ensures that your codebase is scanned weekly for newly discovered vulnerabilities even if no code changes are made.
