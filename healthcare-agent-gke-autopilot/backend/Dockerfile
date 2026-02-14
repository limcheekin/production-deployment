# Use Python 3.11 slim image
FROM python:3.11-slim

# 1. Update the pip tools immediately to overwrite pre-installed versions
# This fixes the vulnerability in the global environment
RUN pip install --no-cache-dir --upgrade "wheel>=0.46.2" "jaraco.context>=6.1.0" setuptools

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first (for better caching)
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Force upgrade vulnerable packages and remove vulnerable binaries from parlant
RUN pip install --no-cache-dir --upgrade "fastmcp>=2.14.0" "setuptools>=82.0.0" "wheel>=0.46.2" && \
    rm -rf /usr/local/lib/python3.11/site-packages/parlant/api/chat/node_modules

# Copy application code
COPY *.py .

# Expose Parlant's default port
EXPOSE 8800

# Create a non-root user
RUN useradd -m -u 1000 parlant && \
    chown -R parlant:parlant /app

# Switch to non-root user
USER parlant

# Set PARLANT_HOME to a writable location
ENV PARLANT_HOME=/tmp/parlant-data

# Health check endpoint
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import requests; requests.get('http://localhost:8800/healthz')" || exit 1

# Run the application
CMD ["python", "main.py"]