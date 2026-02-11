# AI Response Streaming Diagnosis

## Problem
AI responses appear all at once instead of streaming token-by-token in the chat interface.

## Root Cause Analysis

### Frontend Implementation (✅ Correct)
The frontend is properly set up for streaming:

1. **SSE Subscription** ([use-parlant.ts:143-186](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/frontend/src/hooks/use-parlant.ts#L143-L186))
   - Subscribes to `subscribeToEvent()` for each AI message
   - Updates message content on every SSE event
   - React re-renders the `ChatBubble` component with updated content

2. **Message Content Extraction** ([use-parlant.ts:57-68](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/frontend/src/hooks/use-parlant.ts#L57-L68))
   - Correctly joins chunks from `event.data.chunks`
   - Falls back to `event.message` if no chunks

### Most Likely Issue: Backend Behavior

The streaming problem is almost certainly caused by **how the backend sends SSE events**:

#### Scenario 1: Single Event After Completion ❌
```
Event 1: { chunks: ["Hello, how can I help you today?"], message: "..." } // Complete message, sent once
```
**Result**: Message appears all at once

#### Scenario 2: Proper Incremental Streaming ✅
```
Event 1: { chunks: ["Hello"] }
Event 2: { chunks: ["Hello", ", how"] }
Event 3: { chunks: ["Hello", ", how", " can"] }
...
Event N: { chunks: ["Hello", ", how", " can", " I", " help", " you", " today?"] }
```
**Result**: Message appears token-by-token

## Diagnostic Steps

### Step 1: Check Browser Console
Added debug logging to track SSE events. Open browser DevTools Console and send a message to the AI. Look for:

```
[STREAMING DEBUG] Subscribing to AI message event: <eventId>
[STREAMING DEBUG] SSE Update received for <eventId>: {
  contentLength: <number>,
  contentPreview: "...",
  hasChunks: true/false,
  chunkCount: <number>,
  timestamp: "..."
}
```

**What to look for:**
- **Few events** (1-2): Backend is NOT streaming incrementally → Backend issue
- **Many events** with increasing `contentLength`: Streaming is working → Frontend render issue
- **Many events** with same `contentLength`: Backend is sending duplicates → Backend issue

### Step 2: Verify Backend SSE Implementation

Check the Parlant backend `/sessions/{sessionId}/events/{eventId}` endpoint:

**Expected behavior:**
### Investigation Findings (Deep-Dive)

- **Parlant SDK 3.2.0**: The investigation revealed that both `VertexAIService` and `GeminiService` adapters in the Parlant SDK have `supports_streaming` hardcoded to return `False`.
- **Implementation Gap**: In `parlant/adapters/nlp/vertex_service.py` (line 772) and `parlant/adapters/nlp/gemini_service.py` (line 468), the `supports_streaming` property is return `False`, and `get_streaming_text_generator` is not implemented (raises `NotImplementedError`).
- **Underlying Support**: Although the `google-genai` Python library used by these adapters supports `stream_generate_content`, the Parlant SDK has not yet bridged this capability into its `StreamingTextGenerator` interface for Google models.
- **Comparison**: In contrast, the `OpenAIService` in the same SDK *does* implement `StreamingTextGenerator` and returns `True` for `supports_streaming`.
- **Backend Fallback**: The `CannedResponseGenerator` (at line 1050 of `parlant/core/engines/alpha/canned_response_generator.py`) explicitly checks for the presence of a streaming generator. If missing, it logs the warning: *"Agent is configured for streaming message output, but no streaming text generator is available in active NLP Service. Falling back to standard response generation."*

### Recommendation

To enable streaming with Vertex AI, a `StreamingTextGenerator` implementation for Vertex AI needs to be added to the Parlant SDK. Alternatively, switching to the Gemini API (provided the version of the SDK used supports it - noting that version 3.2.0 currently shown also has it disabled for `GeminiService`) or OpenAI would be necessary. 

> [!IMPORTANT]
> Since the current Parlant SDK (v3.2.0) explicitly disables streaming for both Vertex AI and Gemini, simply switching to Gemini might not immediately solve the issue unless a different version or a custom implementation is used.
1. When AI generates tokens, backend should send SSE event for **each token or small batch**
2. Each event should contain **cumulative chunks** (all tokens so far)
3. Events should be sent **immediately** as tokens are generated, not buffered

**Common backend mistakes:**
- Buffering entire response before sending first SSE event
- Sending only one event after completion
- Not flushing SSE stream after each chunk

## Solutions

### If Backend Issue (Most Likely)

The Parlant backend needs to be configured or modified to send incremental SSE updates. Check:

1. **Vertex AI Streaming Configuration**: Ensure the backend is using Vertex AI's streaming API correctly
2. **SSE Event Emission**: Backend should emit an event for each chunk received from Vertex AI
3. **Response Buffering**: Disable any response buffering in the backend server

### If Frontend Issue (Less Likely)

If logs show many SSE events arriving but UI doesn't update smoothly:

1. **React Render Optimization**: Add `useMemo` to prevent unnecessary re-renders
2. **Debouncing**: Events might be arriving too fast for React to render each one

## Next Steps

1. ✅ Debug logging added - check browser console
2. ⏳ Test by sending a message to the AI agent
3. ⏳ Analyze console logs to identify the issue
4. ⏳ Fix backend or frontend based on findings
