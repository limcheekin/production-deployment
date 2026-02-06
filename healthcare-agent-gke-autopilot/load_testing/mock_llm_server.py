"""
Mock LLM Server for Simulated Scale Testing

This FastAPI server mimics the Google Gemini API to enable infrastructure load testing
without incurring actual LLM costs. It simulates realistic latency patterns and streaming
responses to stress-test the Parlant agent infrastructure.

Key Features:
- Gemini API compatible endpoint (/v1beta/models/{model}:streamGenerateContent)
- Configurable latency injection (Gaussian distribution)
- Streaming SSE responses with inter-token delays
- Health check endpoint for Kubernetes probes

Configuration via environment variables:
- MOCK_MIN_LATENCY: Minimum thinking time in seconds (default: 0.5)
- MOCK_MAX_LATENCY: Maximum thinking time in seconds (default: 2.0)
- MOCK_TOKEN_DELAY: Delay between tokens in seconds (default: 0.05)
- MOCK_TOKEN_COUNT: Number of tokens to generate (default: 20)
"""

import asyncio
import json
import os
import random
import time
from typing import AsyncGenerator

from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

app = FastAPI(
    title="Mock LLM Server",
    description="Gemini API compatible mock for simulated scale testing",
    version="1.0.0"
)

# Configuration from environment
MIN_LATENCY = float(os.environ.get("MOCK_MIN_LATENCY", "0.5"))
MAX_LATENCY = float(os.environ.get("MOCK_MAX_LATENCY", "2.0"))
TOKEN_DELAY = float(os.environ.get("MOCK_TOKEN_DELAY", "0.05"))
TOKEN_COUNT = int(os.environ.get("MOCK_TOKEN_COUNT", "20"))


class GeminiRequest(BaseModel):
    """Simplified Gemini API request model."""
    contents: list
    generationConfig: dict = {}
    
    class Config:
        extra = "allow"


async def generate_streaming_response(model: str) -> AsyncGenerator[bytes, None]:
    """
    Generate a streaming SSE response that mimics Gemini API behavior.
    
    Simulates:
    1. Initial "thinking" delay (LLM processing time)
    2. Token-by-token generation with inter-token delays
    3. Proper SSE termination
    """
    # Simulate LLM thinking time (Gaussian distribution within bounds)
    thinking_time = random.uniform(MIN_LATENCY, MAX_LATENCY)
    await asyncio.sleep(thinking_time)
    
    # Generate mock response tokens
    mock_response = "I understand your request. Let me help you with that. "
    mock_response += "Based on the information provided, here is my response. "
    mock_response += "Please let me know if you need any clarification."
    
    words = mock_response.split()
    
    for i, word in enumerate(words[:TOKEN_COUNT]):
        # Gemini streaming format
        chunk = {
            "candidates": [{
                "content": {
                    "parts": [{"text": word + " "}],
                    "role": "model"
                },
                "finishReason": None if i < len(words) - 1 else "STOP",
                "index": 0
            }],
            "usageMetadata": {
                "promptTokenCount": 10,
                "candidatesTokenCount": i + 1,
                "totalTokenCount": 10 + i + 1
            }
        }
        
        yield f"data: {json.dumps(chunk)}\n\n".encode()
        
        # Simulate inter-token latency
        await asyncio.sleep(TOKEN_DELAY)
    
    # Signal end of stream
    yield b"data: [DONE]\n\n"


@app.post("/v1beta/models/{model}:streamGenerateContent")
async def stream_generate_content(model: str, request: Request):
    """
    Gemini API compatible streaming endpoint.
    
    This endpoint is called by the Parlant SDK when using p.NLPServices.gemini.
    It returns a streaming SSE response that mimics real LLM generation.
    """
    return StreamingResponse(
        generate_streaming_response(model),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no"
        }
    )


@app.post("/v1beta/models/{model}:generateContent")
async def generate_content(model: str, request: GeminiRequest):
    """
    Non-streaming Gemini API endpoint for simple requests.
    """
    # Simulate thinking time
    await asyncio.sleep(random.uniform(MIN_LATENCY, MAX_LATENCY))
    
    return {
        "candidates": [{
            "content": {
                "parts": [{
                    "text": "I understand your request. Here is my response based on the information provided."
                }],
                "role": "model"
            },
            "finishReason": "STOP",
            "index": 0
        }],
        "usageMetadata": {
            "promptTokenCount": 10,
            "candidatesTokenCount": 15,
            "totalTokenCount": 25
        }
    }


@app.post("/v1beta/models/{model}:batchEmbedContents")
async def batch_embed_contents(model: str, request: Request):
    """
    Mock batch embeddings endpoint for Gemini embedding API.
    
    Returns dummy 768-dimensional embeddings for each content item.
    The Parlant SDK uses this for entity embedding caching on startup.
    
    Note: Returns a distinct dense vector to avoid NaN errors (normalization)
    and vector DB indexing errors (duplicates).
    """
    try:
        body = await request.json()
        requests_list = body.get("requests", [])
        
        # Generate mock embeddings (768 dimensions)
        # Use a dense vector with variation to ensure safe normalization AND distinctness
        embeddings = []
        for i, _ in enumerate(requests_list):
            vec = [0.1] * 768
            # Add variation to ensure vectors are distinct
            # (Identical vectors can crash some vector DB indexers)
            vec[i % 768] = 0.9 
            embeddings.append({"values": vec})
        
        return {
            "embeddings": embeddings
        }
    except Exception:
        # Return at least one dense vector embedding if request parsing fails
        vec = [0.1] * 768
        vec[0] = 0.9
        return {
            "embeddings": [{"values": vec}]
        }


@app.post("/v1beta/models/{model}:embedContent")
async def embed_content(model: str, request: Request):
    """
    Mock single embedding endpoint for Gemini embedding API.
    """
    vec = [0.1] * 768  # Dense vector
    vec[0] = 0.9       # Variation
    return {
        "embedding": {
            "values": vec
        }
    }


@app.get("/health")
async def health_check():
    """Health check endpoint for Kubernetes probes."""
    return {"status": "ok", "timestamp": int(time.time())}


@app.get("/")
async def root():
    """Root endpoint with service information."""
    return {
        "service": "Mock LLM Server",
        "version": "1.0.0",
        "config": {
            "min_latency": MIN_LATENCY,
            "max_latency": MAX_LATENCY,
            "token_delay": TOKEN_DELAY,
            "token_count": TOKEN_COUNT
        }
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
