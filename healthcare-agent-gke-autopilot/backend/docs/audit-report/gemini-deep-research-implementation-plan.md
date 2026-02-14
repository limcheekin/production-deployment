# Audit Remediation: Gemini Deep Research Findings (Items 2–7)

Implements fixes for all confirmed findings in the security & reliability audit, excluding Item 1 (Vertex AI streaming — SDK limitation outside project scope).

## Proposed Changes

### Security: IAM & CI/CD

#### [MODIFY] [setup-github-wif.sh](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/backend/setup-github-wif.sh)

**SEC-001 (P0):** Downgrade `roles/artifactregistry.admin` → `roles/artifactregistry.writer`. The CI SA only needs to push images, not manage repository IAM or delete images.

```diff
-    --role="roles/artifactregistry.admin" \
+    --role="roles/artifactregistry.writer" \
```

Also update the comment on the line above from "Admin" to "Writer".

---

### Security & Code Quality: main.py

#### [MODIFY] [main.py](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/backend/main.py)

Three findings addressed in this file:

**SEC-002 (P2):** Extract monkey-patching logic (lines 13–72) into a new `main_load_test.py` entry point. The production `main.py` should contain zero test/mock code.

**SEC-003 (P2):** Replace hardcoded `allow_origins=["*"]` with environment-configurable `ALLOWED_ORIGINS`.

```diff
 async def configure_api(app: FastAPI) -> None:
+    origins = os.environ.get("ALLOWED_ORIGINS", "*").split(",")
     app.add_middleware(
         CORSMiddleware,
-        allow_origins=["*"],  # In production, specify your frontend domain
+        allow_origins=origins,
         allow_credentials=True,
```

**SEC-004 (P3):** Replace all `print("DEBUG: ...")` statements with `logging.getLogger(__name__)` calls. Production `main.py` already imports a `JsonFormatter` from `production_config.py`. Use `logger.info()` for normal flow and `logger.error()` for failures.

#### [NEW] [main_load_test.py](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/backend/main_load_test.py)

New entry point for load testing with mock LLM. Contains the monkey-patching logic extracted from `main.py`, then imports and calls the production `main()`.

---

### Infrastructure: UID Alignment

#### [MODIFY] [Dockerfile-GKE-Autopilot](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/backend/Dockerfile-GKE-Autopilot)

**OPS-001 (P1):** Add explicit UID 1000 to the `useradd` command to match the `runAsUser` value we'll set in `setup.sh`.

```diff
-RUN groupadd -r parlant && useradd -r -g parlant -m -d /home/parlant parlant
+RUN groupadd -r parlant && useradd -r -g parlant -u 1000 -m -d /home/parlant parlant
```

Also update `CMD` to use an env var so `main_load_test.py` can be used in load testing:

```diff
-CMD ["python", "main.py"]
+CMD ["sh", "-c", "python ${PARLANT_ENTRYPOINT:-main.py}"]
```

#### [MODIFY] [setup.sh](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/backend/setup.sh)

**OPS-001 (P1):** Change `runAsUser: 999` → `runAsUser: 1000` in the Parlant deployment manifest to match the Dockerfile UID.

Also add `ALLOWED_ORIGINS` env var (defaulting to `*` — users should override via their setup).

---

### Infrastructure: MongoDB & Config

#### [MODIFY] [production_config.py](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/backend/production_config.py)

**OPS-003 (P2):** Add `maxPoolSize=50` to MongoDB connection URIs to prevent M0 connection exhaustion.

**OPS-004 (P3):** Fix the model comment — change `claude-sonnet-3.5` → `gemini-2.5-flash`.

---

### Load Testing: Entry Point Update

#### [MODIFY] [redeploy-for-load-testing.sh](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/backend/load_testing/redeploy-for-load-testing.sh)

Update `reconfigure_parlant()` to set `PARLANT_ENTRYPOINT=main_load_test.py` env var so Parlant uses the load-test entry point with monkey-patching.

Update `revert_to_production()` to remove the `PARLANT_ENTRYPOINT` env var when reverting.

---

## Verification Plan

### Automated Checks

Since this is an infrastructure/deployment project with no Python unit test framework, verification is script-based:

```bash
# 1. Verify UID alignment
DOCKER_UID=$(grep "useradd" Dockerfile-GKE-Autopilot | grep -oP '\-u \K[0-9]+')
SETUP_UID=$(grep "runAsUser" setup.sh | grep -o '[0-9]*' | head -1)
echo "Dockerfile UID: $DOCKER_UID, setup.sh UID: $SETUP_UID"
[ "$DOCKER_UID" = "$SETUP_UID" ] && echo "✅ Match" || echo "❌ Mismatch"

# 2. Verify IAM role is writer not admin
grep "artifactregistry" setup-github-wif.sh

# 3. Verify maxPoolSize in production_config.py
grep "maxPoolSize" production_config.py

# 4. Verify no DEBUG prints in main.py
grep -c "print.*DEBUG" main.py  # should be 0

# 5. Verify no monkey-patching in main.py
grep -c "monkey-patch\|unittest.mock" main.py  # should be 0

# 6. Verify ALLOWED_ORIGINS in main.py
grep "ALLOWED_ORIGINS" main.py

# 7. Verify model comment in production_config.py
grep "gemini-2.5-flash" production_config.py

# 8. Verify main_load_test.py exists and has monkey-patching
[ -f main_load_test.py ] && echo "✅ File exists" || echo "❌ Missing"
grep -c "monkey-patch" main_load_test.py
```

### Manual Verification

The user should verify after deploying:

1. **CORS:** `curl -I -H "Origin: http://evil.com" <API_URL>` should not return `Access-Control-Allow-Origin: http://evil.com` unless `ALLOWED_ORIGINS` includes it
2. **UID:** `kubectl exec <pod> -- id` should show UID 1000
3. **Load test mode:** Running `redeploy-for-load-testing.sh` should use `main_load_test.py` entry point
