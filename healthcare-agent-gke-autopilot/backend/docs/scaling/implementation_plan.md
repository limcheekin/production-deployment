# Scaling Guide Review & Rewrite

## Problem

The [guide.md](file:///production-deployment/healthcare-agent-gke-autopilot/backend/docs/scaling/guide.md) contains factual errors, incomplete content, and mismatches with the actual deployment. Related scripts also have inconsistencies with `setup.sh`.

## Review Findings

### A. Guide Content Issues

| # | Line(s) | Issue | Severity |
|---|---------|-------|----------|
| 1 | 1–3 | No title — opens with prose, references an unspecified "official guide" | Medium |
| 2 | 42 | **Orphan bullet** — `* .` (broken formula) | High |
| 3 | 48 | **Missing formula** — `maxPoolSize` formula blank after colon | High |
| 4 | 10 | References **GPT-4o** — project uses **Vertex AI / Gemini 2.5 Flash** | High |
| 5 | 58–59, 63 | References **OpenAI / Anthropic** — should be **Vertex AI** | High |
| 6 | 55 | Claims `/health` endpoint — actual probes use `/healthz` | Medium |
| 7 | 38 | Claims M10/M20 limit is ~1,500 connections — actual M10≈350, M20≈500. Project uses **M0 Free Tier** (500 limit) | High |
| 8 | 75 | Summary table Row 5 "Redis Leaky Bucket" — never discussed in body | Medium |

### B. Cross-Script Bugs (Pre-existing, Not Caused by Guide)

> [!CAUTION]
> These are real bugs in the revert script that could cause production incidents.

| # | File | Issue |
|---|------|-------|
| 9 | [redeploy:192](file:///production-deployment/healthcare-agent-gke-autopilot/backend/load_testing/redeploy-for-load-testing.sh#L192) | **Stale comment**: "startupProbe is not present in setup.sh" — but `setup.sh` has it at lines 482–487 |
| 10 | [redeploy:198](file:///production-deployment/healthcare-agent-gke-autopilot/backend/load_testing/redeploy-for-load-testing.sh#L198) | **`failureThreshold` mismatch**: revert uses `30` (=300s), but `setup.sh` uses `60` (=600s). After reverting, pods get **half the startup time** they need for Vertex AI initialization |
| 11 | [redeploy:188-191](file:///production-deployment/healthcare-agent-gke-autopilot/backend/load_testing/redeploy-for-load-testing.sh#L188) | **`readinessProbe` parameter mismatch**: revert adds `periodSeconds: 10`, `timeoutSeconds: 5`, `failureThreshold: 3` — but `setup.sh` only specifies `initialDelaySeconds: 10` on readinessProbe |

### C. Missing Production Hardening (Not Yet in setup.sh)

| # | What | Why |
|---|------|-----|
| 12 | `terminationGracePeriodSeconds: 120` | Default 30s is too short for agentic workflows (45–90s). Pod gets killed mid-response. |
| 13 | `preStop` lifecycle hook | Pod should stop receiving new traffic before shutdown, allowing in-flight requests to complete. |

## Proposed Changes

### 1. [MODIFY] [guide.md](file:///production-deployment/healthcare-agent-gke-autopilot/backend/docs/scaling/guide.md)

Full rewrite addressing findings #1–8:
- Add proper title and intro
- Fix LLM references → Vertex AI / Gemini
- Fix broken formulas with actual math: `maxPoolSize = DB_limit / max_pods`
- Correct MongoDB tier limits (use M0 Free Tier context)
- Accurately describe `/healthz` probes and `startupProbe` config
- Add Section 5 for Rate Limiting (currently orphaned in summary table)
- Add actionable YAML snippets for `terminationGracePeriodSeconds` and `preStop`
- Note that probe decoupling is an **app-level recommendation** (requires custom endpoints in `main.py`) — not implemented here

---

### 2. [MODIFY] [setup.sh](file:///production-deployment/healthcare-agent-gke-autopilot/backend/setup.sh)

Lines 413–418 — Add to pod spec (same level as `containers:`):

```yaml
      terminationGracePeriodSeconds: 120
      containers:
      - name: parlant
        lifecycle:
          preStop:
            exec:
              command: ["sleep", "5"]
```

> [!NOTE]
> The `sleep 5` preStop hook gives the Service time to remove the pod from its endpoint list before the process receives SIGTERM, preventing in-flight requests from being interrupted.

---

### 3. [MODIFY] [redeploy-for-load-testing.sh](file:///production-deployment/healthcare-agent-gke-autopilot/backend/load_testing/redeploy-for-load-testing.sh)

Fix findings #9–11 in the `revert_to_production()` patch (lines 162–200):
- Delete stale comments on lines 192–193
- Fix `startupProbe.failureThreshold` from `30` → `60` to match `setup.sh`
- Remove extra `readinessProbe` fields (`periodSeconds`, `timeoutSeconds`, `failureThreshold`) so it matches `setup.sh`
- Add `terminationGracePeriodSeconds: 120` and `preStop` lifecycle hook to match updated `setup.sh`

---

### 4. [MODIFY] [verify.sh](file:///production-deployment/healthcare-agent-gke-autopilot/backend/verify.sh)

Add new checks after the existing Deployment section (~line 383):
- Verify `terminationGracePeriodSeconds` is `120`
- Verify `preStop` lifecycle hook exists
- Verify `startupProbe.failureThreshold` is `60`

---

### 5. [NO CHANGE] [clean-up.sh](file:///production-deployment/healthcare-agent-gke-autopilot/backend/clean-up.sh)

Only deletes resources. No manifest-level configs to update.

## Verification Plan

1. Confirm updated `setup.sh` YAML is syntactically valid
2. Confirm `revert_to_production()` patch exactly matches updated `setup.sh` probe/lifecycle config
3. Confirm `verify.sh` new checks use correct jsonpath queries
4. Read guide end-to-end for coherence
