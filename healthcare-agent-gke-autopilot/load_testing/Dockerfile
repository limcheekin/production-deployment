# Mock LLM Server Dockerfile
# Lightweight container for simulated scale testing

FROM python:3.11-slim

WORKDIR /app

# Install dependencies
RUN pip install --no-cache-dir fastapi uvicorn pydantic

# Copy application
COPY mock_llm_server.py .

# Expose port
EXPOSE 8000

# Health check
HEALTHCHECK --interval=10s --timeout=5s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

# Run with multiple workers for concurrency
CMD ["uvicorn", "mock_llm_server:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "4"]
