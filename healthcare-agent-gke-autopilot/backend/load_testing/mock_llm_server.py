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
import json
import random

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
    tools: list = []
    
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
    print(f"DEBUG: generate_content request for {model}: {request.model_dump_json(indent=2)}")
    # Check for tools in the request
    tools = []
    if hasattr(request, "tools"):
        tools = request.tools
    
    # If tools are present, we must return a function call to satisfy Parlant's assertions
    if tools:
        # Extract the first function declaration (handling both dicts and Pydantic models)
        function_declarations = []
        for tool in tools:
            # Check if tool is a dict or object
            if isinstance(tool, dict):
                fds = tool.get("functionDeclarations", [])
            else:
                # Assume Pydantic model or object
                fds = getattr(tool, "functionDeclarations", [])
                
            if fds:
                function_declarations.extend(fds)
        
        if function_declarations:
            first_fn = function_declarations[0]
            
            # Access name safely
            if isinstance(first_fn, dict):
                fn_name = first_fn.get("name")
            else:
                fn_name = getattr(first_fn, "name", "unknown_function")
            
            print(f"DEBUG: Handling tool call for function: {fn_name}")

            # Construct a dummy response based on the function name
            # This is a heuristic to provide "valid-enough" data for Parlant's schemas
            args = {}
            
            # Inspect properties to disambiguate generic "log_data" function
            props = {}
            if isinstance(first_fn, dict):
                 props = first_fn.get("parameters", {}).get("properties", {})
            else:
                 # Pydantic model
                 params = getattr(first_fn, "parameters", None)
                 if params:
                     if isinstance(params, dict):
                         props = params.get("properties", {})
                     else:
                         props = getattr(params, "properties", {})

            # Heuristics for known Parlant schemas
            if "CustomerDependent" in fn_name:
                args = {
                    "action": "reply",
                    "is_customer_dependent": False,
                    "customer_action": None,
                    "agent_action": None
                }
            elif "Guideline" in fn_name:
                # GuidelineContinuousPropositionSchema require rationale and is_continuous
                args = {
                    "propositions": [
                        {
                            "condition": "always",
                            "action": "reply with a greeting",
                            "rationale": "Greeting is polite",
                            "is_continuous": True
                        }
                    ]
                }
            elif fn_name == "log_data":
                # Handle generic log_data function used by Parlant for structured output
                # Check for nested 'log_data' property wrapper
                check_props = props
                is_wrapped = False
                
                if "log_data" in props:
                    # Parlant typically wraps the schema in a single 'log_data' argument
                    p = props["log_data"]
                    if isinstance(p, dict):
                        check_props = p.get("properties", {})
                    else:
                        check_props = getattr(p, "properties", {})
                    is_wrapped = True

                if "is_continuous" in check_props:
                     inner_args = {
                        "rationale": "Greeting is polite",
                        "is_continuous": True
                    }
                     args = {"log_data": inner_args} if is_wrapped else inner_args
                elif "is_customer_dependent" in check_props:
                     inner_args = {
                        "action": "reply",
                        "is_customer_dependent": False,
                        "customer_action": None,
                        "agent_action": None
                     }
                     args = {"log_data": inner_args} if is_wrapped else inner_args
                elif "is_agent_intention" in check_props:
                     inner_args = {
                        "condition": "The user wants to schedule an appointment",
                        "is_agent_intention": True
                     }
                     args = {"log_data": inner_args} if is_wrapped else inner_args
                elif "is_tool_running_only" in check_props:
                     inner_args = {
                        "action": "Use the tool",
                        "rationale": "The user request requires a tool",
                        "is_tool_running_only": True
                     }
                     args = {"log_data": inner_args} if is_wrapped else inner_args
                elif "actions" in check_props:
                     inner_args = {
                        "actions": [
                            {
                                "index": "1",
                                "conditions": ["Always"],
                                "action": "Do something",
                                "needs_rewrite_rationale": "No need",
                                "needs_rewrite": False
                            }
                        ]
                     }
                     args = {"log_data": inner_args} if is_wrapped else inner_args
                elif "step_action" in check_props:
                     inner_args = {
                        "step_action": "Do something",
                        "step_action_completed": "true"
                     }
                     args = {"log_data": inner_args} if is_wrapped else inner_args
            elif "Coherence" in fn_name:
                 args = {"is_coherent": True}
            
            # Fallback to ensure args is never empty, as Parlant asserts this
            if not args:
                args = {"status": "mock_response"}

            return {
                "candidates": [{
                    "content": {
                        "parts": [{
                            "functionCall": {
                                "name": fn_name,
                                "args": args
                            }
                        }],
                        "role": "model"
                    },
                    "finishReason": "STOP",
                    "index": 0
                }],
                "usageMetadata": {
                    "promptTokenCount": 50,
                    "candidatesTokenCount": 20,
                    "totalTokenCount": 70
                }
            }
            
    # Check for JSON mode (responseMimeType="application/json")
    generation_config = getattr(request, "generationConfig", {}) or {}
    response_mime_type = generation_config.get("responseMimeType", "")
    
    if "application/json" in response_mime_type:
        print("DEBUG: Handling JSON mode request")
        # Inspect prompt to determine schema
        prompt_text = ""
        for content in request.contents:
            # Handle list of dicts or list of objects
            # contents is list[Content] or list[dict]
            # content.parts is list[Part] or list[dict]
            
            # Helper to get parts
            if isinstance(content, dict):
                parts = content.get("parts", [])
            else:
                parts = getattr(content, "parts", [])
                
            for part in parts:
                if isinstance(part, dict):
                    prompt_text += part.get("text", "")
                else:
                    prompt_text += getattr(part, "text", "")
        
        print(f"DEBUG: Prompt text snippet: {prompt_text[:100]}...")
        
        json_response = {}
        # Simple heuristics based on keywords in prompt
        # We need to match GuidelineContinuousPropositionSchema and CustomerDependentActionSchema
        
        # Check responseSchema title first
        schema_title = generation_config.get("responseSchema", {}).get("title", "")
        print(f"DEBUG: Schema title: {schema_title}")
        
        if schema_title == "CustomerDependentActionSchema":
             json_response = {
                 "action": "reply",
                 "is_customer_dependent": False
             }
        elif schema_title == "AgentIntentionProposerSchema":
             json_response = {
                 "condition": "The user greets",
                 "is_agent_intention": False
             }
        elif schema_title == "ToolRunningActionSchema":
             json_response = {
                 "action": "reply",
                 "rationale": "No tool needed",
                 "is_tool_running_only": False
             }
        elif schema_title == "GuidelineContinuousPropositionSchema":
             json_response = {
                "rationale": "Greeting is polite",
                "is_continuous": True
            }
        elif schema_title == "RelativeActionSchema":
             json_response = {
                 "actions": [
                     {
                         "index": "0",
                         "conditions": [],
                         "action": "reply",
                         "needs_rewrite_rationale": "No rewrite needed",
                         "needs_rewrite": False
                     }
                 ]
             }
        elif schema_title == "ReachableNodesEvaluationSchema":
             json_response = {
                 "step_action": "Do something",
                 "step_action_completed": "true",
                 "children_conditions": None
             }
        elif schema_title == "CannedResponsePreambleSchema":
             json_response = {
                 "preamble": "I verified the information."
             }
        elif schema_title == "DisambiguationGuidelineMatchesSchema":
             json_response = {
                 "tldr": "User wants to do something",
                 "ambiguity_condition_met": False,
                 "disambiguation_requested": False,
                 "is_ambiguous": False,
                 "guidelines": [],
                 "clarification_action": None
             }
        elif schema_title == "GenericObservationalGuidelineMatchesSchema":
             json_response = {
                 "checks": []
             }
        elif "is_customer_dependent" in prompt_text.lower():
             # Likely CustomerDependentActionSchema
             json_response = {
                 "action": "reply",
                 "is_customer_dependent": False
             }
        elif "is_agent_intention" in prompt_text.lower():
             # Likely AgentIntentionProposerSchema
             json_response = {
                 "condition": "The user greets",
                 "is_agent_intention": False
             }
        elif "is_tool_running_only" in prompt_text.lower():
             # Likely ToolRunningActionSchema
             json_response = {
                 "action": "reply",
                 "rationale": "No tool needed",
                 "is_tool_running_only": False
             }
        elif "is_continuous" in prompt_text.lower():
             # Likely GuidelineContinuousPropositionSchema
             json_response = {
                 "rationale": "Greeting is polite",
                 "is_continuous": True
            }
        elif "needs_rewrite" in prompt_text.lower():
             # Likely RelativeActionSchema
             json_response = {
                 "actions": [
                     {
                         "index": "0",
                         "conditions": [],
                         "action": "reply",
                         "needs_rewrite_rationale": "No rewrite needed",
                         "needs_rewrite": False
                     }
                 ]
             }
        elif "step_action" in prompt_text.lower():
             # Likely ReachableNodesEvaluationSchema
             json_response = {
                 "step_action": "Do something",
                 "step_action_completed": "true",
                 "children_conditions": None
             }
        elif "preamble" in prompt_text.lower():
             # Likely CannedResponsePreambleSchema
             json_response = {
                 "preamble": "I verified the information."
             }
        elif "is_ambiguous" in prompt_text.lower() or "ambiguity" in prompt_text.lower():
             # Likely DisambiguationGuidelineMatchesSchema
             json_response = {
                 "tldr": "User wants to do something",
                 "ambiguity_condition_met": False,
                 "disambiguation_requested": False,
                 "is_ambiguous": False,
                 "guidelines": [],
                 "clarification_action": None
             }
        else:
             # Fallback to dynamic generation from schema
             response_schema = generation_config.get("responseSchema")
             if response_schema:
                 print(f"DEBUG: Generating dynamic response for schema: {schema_title}")
                 json_response = generate_mock_from_schema(response_schema)
             else:
                 # Fallback JSON to avoid empty response if we missed the heuristic and no schema
                 json_response = {
                     "status": "mock_json_response", 
                     "note": "Unidentified schema in prompt"
                 }

        return {
            "candidates": [{
                "content": {
                    "parts": [{
                        "text": json.dumps(json_response)
                    }],
                    "role": "model"
                },
                "finishReason": "STOP",
                "index": 0
            }],
            "usageMetadata": {
                "promptTokenCount": 50,
                "candidatesTokenCount": 20,
                "totalTokenCount": 70
            }
        }

    # Default text response
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
        
        # Generate mock embeddings (3072 dimensions) to match what Parlant seems to expect
        # Use a dense vector with variation to ensure safe normalization AND distinctness
        embeddings = []
        for i, _ in enumerate(requests_list):
            vec = [0.1] * 3072
            # Add variation to ensure vectors are distinct
            # (Identical vectors can crash some vector DB indexers)
            vec[i % 3072] = 0.9 
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
@app.post("/v1beta/models/{model}:predict")
async def embed_content(model: str, request: Request):
    """
    Mock single embedding endpoint for Gemini embedding API.
    Also handles vertex AI :predict endpoint which is used for text-embedding-004.
    """
    print(f"DEBUG: embed_content/predict request for {model}")
    # Vertex AI predict format might differ from Gemini embedContent format
    # But usually it contains 'instances' list.
    # Gemini uses 'content'.
    
    # We'll just return a dummy response that fits both if possible,
    # or check the body.
    
    body = await request.json()
    print(f"DEBUG: request body: {json.dumps(body)}")
    
    vec = [0.1] * 768  # text-embedding-004 is 768 dim
    vec[0] = 0.9       # Variation
    
    # Vertex AI predict response format:
    # { "predictions": [ { "embeddings": { "values": [...] } } ] }
    # Gemini embedContent response format:
    # { "embedding": { "values": [...] } }
    
    if "instances" in body:
        # Vertex AI Predict format
        return {
            "predictions": [
                {
                    "embeddings": {
                        "values": vec
                    }
                } for _ in body["instances"]
            ]
        }
    else:
        # Gemini format
        return {
            "embedding": {
                "values": vec
            }
        }


@app.post("/v1beta/models/{model}:countTokens")
async def count_tokens(model: str, request: Request):
    """
    Mock countTokens endpoint.
    """
    return {
        "totalTokens": 50
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



def generate_mock_from_schema(schema: dict) -> any:
    """Recursively generate mock data based on a JSON schema."""
    if not schema:
        return {}
    
    schema_type = schema.get("type", "OBJECT").upper()
    
    if schema_type == "OBJECT":
        properties = schema.get("properties", {})
        result = {}
        for key, prop_schema in properties.items():
            result[key] = generate_mock_from_schema(prop_schema)
        return result
    
    elif schema_type == "ARRAY":
        items_schema = schema.get("items", {})
        # Generate one item for the array
        return [generate_mock_from_schema(items_schema)]
    
    elif schema_type == "STRING":
        if "enum" in schema:
            return schema["enum"][0]
        return "mock_string"
    
    elif schema_type == "BOOLEAN":
        return False
    
    elif schema_type == "INTEGER":
        return 1
    
    elif schema_type == "NUMBER":
        return 1.0
        
    return None

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
