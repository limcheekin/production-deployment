"""
Load testing entry point with mock LLM monkey-patching.

This module applies monkey-patches to redirect Vertex AI traffic to
a local mock LLM server, then delegates to the production main().

Usage:
    Set PARLANT_ENTRYPOINT=main_load_test.py in the container environment,
    or run directly: python main_load_test.py

Required environment variables:
    USE_VERTEX_AI=true
    VERTEX_AI_API_ENDPOINT=mock-llm.default.svc.cluster.local:8000
"""
import os
import re
import logging

logger = logging.getLogger(__name__)

# Only apply monkey-patching when targeting a mock endpoint
_endpoint = os.environ.get("VERTEX_AI_API_ENDPOINT", "")
if os.environ.get("USE_VERTEX_AI") == "true" and "mock" in _endpoint:
    logger.info("Applying monkey-patch for Vertex AI load testing (mock endpoint: %s)", _endpoint)

    # 1. Mock Credentials
    from google.auth.credentials import Credentials
    import google.auth
    from unittest.mock import MagicMock

    class MockCredentials(Credentials):
        def refresh(self, request):
            self.token = "dummy_token"
        def apply(self, headers):
            headers["Authorization"] = "Bearer dummy_token"
        def before_request(self, request, headers):
            self.apply(headers)

    google.auth.default = MagicMock(return_value=(MockCredentials(), "local-project"))

    # 2. Patch httpx to redirect Vertex AI traffic to mock LLM
    import httpx

    original_ac_request = httpx.AsyncClient.request

    async def mocked_ac_request(self, method, url, *args, **kwargs):
        str_url = str(url)
        if "aiplatform.googleapis.com" in str_url:
            logger.debug("Redirecting Vertex AI call (Async): %s", str_url)
            new_url = re.sub(r"https://.*aiplatform\.googleapis\.com", "http://mock-llm:8000", str_url)
            new_url = re.sub(
                r"/v1beta1/projects/.*/locations/.*/publishers/google/models/(.*)",
                r"/v1beta/models/\1",
                new_url
            )
            logger.debug("Redirected to: %s", new_url)
            return await original_ac_request(self, method, new_url, *args, **kwargs)

        return await original_ac_request(self, method, url, *args, **kwargs)

    httpx.AsyncClient.request = mocked_ac_request

    original_c_request = httpx.Client.request

    def mocked_c_request(self, method, url, *args, **kwargs):
        str_url = str(url)
        if "aiplatform.googleapis.com" in str_url:
            logger.debug("Redirecting Vertex AI call (Sync): %s", str_url)
            new_url = re.sub(r"https://.*aiplatform\.googleapis\.com", "http://mock-llm:8000", str_url)
            new_url = re.sub(
                r"/v1beta1/projects/.*/locations/.*/publishers/google/models/(.*)",
                r"/v1beta/models/\1",
                new_url
            )
            logger.debug("Redirected to: %s", new_url)
            return original_c_request(self, method, new_url, *args, **kwargs)

        return original_c_request(self, method, url, *args, **kwargs)

    httpx.Client.request = mocked_c_request

    logger.info("Monkey-patching applied successfully")
else:
    logger.warning(
        "main_load_test.py loaded but mock patching NOT applied "
        "(USE_VERTEX_AI=%s, VERTEX_AI_API_ENDPOINT=%s)",
        os.environ.get("USE_VERTEX_AI"),
        _endpoint,
    )


if __name__ == "__main__":
    # Import after patching so the production code uses the mocked modules
    import asyncio
    from main import main
    asyncio.run(main())
