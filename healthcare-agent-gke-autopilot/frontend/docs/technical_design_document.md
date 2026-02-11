# Technical Design Document: Custom Parlant Chat Integration

**Version:** 2.0.0 (Robust Architecture)
**Status:** DRAFT
**Author:** Distinguished Frontend Engineer (Antigravity)
**Date:** 2026-02-10

## 1. Executive Summary

This document outlines the technical architecture for a bespoke, production-grade chat interface integrating with the Parlant Agent AI. **Critical Pivot:** This design bypasses the `parlant-client` SDK in favor of a strictly typed **REST Adapter** to ensure granular control over connection stability. It utilizes **React 19-compatible** UI strategies ("Copy-Own" components) and enforces robust long-polling mechanisms.

## 2. Core Architecture & Data Integrity

The integration is built on a layered architecture: **REST Adapter Layer** -> **Hook Layer (`useParlantSession`)** -> **Context Layer (`ParlantProvider`)** -> **UI Layer** (Self-contained components).

### 2.1 The "Connection Manager": Typed REST Adapter

**Critique of SDK**: Direct dependency on `parlant-client` creates a black-box risk. 
**Pivot**: We will implement a lightweight, strictly typed `ParlantAdapter` wrapping `fetch`. This ensures full control over polling behavior (timeouts, existing socket keep-alives) and strict mode compatibility.

#### 2.1.1 Adapter Interface
```typescript
// src/lib/parlant-adapter.ts
export class ParlantAdapter {
  constructor(private agentId: string, private baseUrl: string) {}

  async getEvents(minOffset: number, signal?: AbortSignal): Promise<ParlantEvent[]> {
    const url = `${this.baseUrl}/agents/${this.agentId}/events?min_offset=${minOffset}`;
    
    // Explicit 30s timeout matching the server's long-poll window
    const res = await fetch(url, {
      signal,
      headers: { 'Content-Type': 'application/json' },
      cache: 'no-store'
    });

    if (!res.ok) {
       if (res.status >= 400 && res.status < 500) throw new ClientError(res.statusText);
       throw new ServerError(res.statusText);
    }
    
    return res.json();
  }
  
  async sendMessage(message: string): Promise<void> {
    // ... POST implementation
  }
}
```

### 2.2 The Hook: `useParlantSession` (Hardened)

#### 2.2.1 State Management & Offset Synchronization
To ensure strict message ordering and prevent "tear", we track the `minOffset` via a `useRef`. using a ref determines *what to fetch next*, while React state determines *what to render*.

**State Interface:**
```typescript
interface ConnectionState {
  status: 'IDLE' | 'CONNECTING' | 'CONNECTED' | 'RECONNECTING' | 'ERROR';
  sessionId: string | null;
  error: Error | null;
}
```

**Offset Strategy:**
- `lastOffsetRef`: Mutable `React.MutableRefObject<number>` initialized to `0`.
- **Logic**: 
  1. On successful `listEvents` response, iterate through events.
  2. For each event, update `lastOffsetRef.current = Math.max(lastOffsetRef.current, event.offset + 1)`.
  3. Pass `minOffset: lastOffsetRef.current` to the next `listEvents` call.

#### 2.1.2 Deduplication Strategy (Heuristic)
Since `parlant-client` does not echo a client-generated ID, we must deduplicate the "Optimistic" message against the "Server" message (source=`customer`) to prevent double bubbles.

- **Algorithm**:
  1. User sends message "Hello" -> Add to State as `OptimisticMessage` (ID: `temp-1`, status: `sending`).
  2. Server Poll returns `Event` (source: `customer`, content: "Hello").
  3. **Matching**: Find pending `OptimisticMessage` with same content sent within the last 5 seconds.
  4. **Resolution**:
     - *Match Found*: Merge Server Event ID/Timestamp into `OptimisticMessage`. Set status=`delivered`.
     - *No Match*: Treat as a distinct message (e.g., sent from another tab).

#### 2.1.3 Reconnection Logic (Exponential Backoff)
Network instability is expected. "Retry immediately" is not an acceptable strategy for 5xx errors.

- **4xx Errors (Client Error)**: Fatal. Do NOT retry. Transition to `ERROR` state. (e.g., Session expired/invalid).
- **5xx Errors / Network (Server Error)**: Retry with Exponential Backoff + Jitter.
  - Initial delay: 1000ms
  - Max delay: 30,000ms
  - Factor: 1.5
  - Jitter: ±10% random to prevent thundering herd.

#### 2.1.4 Runtime Validation (Zod)
We strictly validate incoming payloads. SDK types are compile-time only guarantees; we need runtime safety.

```typescript
import { z } from 'zod';

const ParlantEventSchema = z.object({
  kind: z.enum(['message', 'status']),
  source: z.enum(['customer', 'agent', 'system']),
  message: z.string().optional(),
  // Strict alignment with SDK: 'data' is generic, validation should be permissive but typesafe
  data: z.record(z.string(), z.unknown()).optional(), 
  offset: z.number(),
});

type ParlantEvent = z.infer<typeof ParlantEventSchema>;
```

## 3. UI/UX & Performance (The "Feel")

### 3.1 Global Context: `ParlantProvider`
To avoid prop drilling and ensure a singleton session per view, wrap the chat in a Provider.

```typescript
const ParlantContext = createContext<ParlantContextValue | null>(null);

export const ParlantProvider = ({ children }: { children: ReactNode }) => {
  const session = useParlantSession(); // The hook from 2.1
  return <ParlantContext.Provider value={session}>{children}</ParlantContext.Provider>;
};
```

### 3.2 Optimistic UI Pattern
Decouple user intent from server confirmation.

**Transitions:**
1. `sending` (Grayed out, spinner)
2. `sent` (Solid color, single checkmark) - *ACK from POST request*
3. `delivered` (Solid, double checkmark) - *Confirmed via Poll*

### 3.3 Rich Text & Sanitization
Agents output Markdown. Rendering raw HTML is an XSS vulnerability.

- **Pipeline**:
  1. Input: Agent Message String
  2. Parser: `react-markdown`
  3. Sanitizer: `rehype-sanitize` (Allow-list ONLY: `b`, `i`, `code`, `p`, `ul`, `li`, `a`).
  4. Component Map: Map `a` tags to a secure link component (`target="_blank" rel="noopener noreferrer"`).
  5. Output: Secure React Components.

### 3.4 Smart Auto-Scroll
- **Ref**: `messagesEndRef`.
- **Logic**:
  - `isNearBottom`: `scrollHeight - scrollTop - clientHeight < 100px`.
  - **New Message Handler**:
    - If `source === 'customer'`, **FORCE SCROLL**.
    - If `source === 'agent'`:
      - If `isNearBottom` -> **AUTO SCROLL**.
      - If `!isNearBottom` -> **SHOW "New Message" TOAST** (Don't hijack scroll).

### 3.5 Message Grouping
To reduce visual clutter, consecutive messages from the same `source` within `X` minutes are grouped.
- **Visuals**: Hide Avatar on 2nd+ message. Reduce margin-top.
- **Implementation**: Mapped in the render loop by comparing `msg[i].source` with `msg[i-1].source`.

## 4. Business Logic Integration (Best Practices)

### 4.1 Utilization of "Journeys" for UI States
Parlant's "Journeys" represent multi-step workflows. The UI must reflect these states to guide the user.

- **Mechanism**: The Agent should emit specific `tag` or `meta` data within the `status` or `message` event to signal the current Journey stage.
- **UI Mapping**:
  - `journey: 'onboarding'` -> Show Progress Bar (Step 1/3)
  - `journey: 'troubleshooting'` -> Show "Diagnostic Mode" Banner
  - `journey: 'resolution'` -> Show "Rate this Interaction" Widget

**Event Payload Extension**:
```typescript
interface MessageData {
  journey_id?: string;
  journey_step?: string; // e.g., "collect_email", "verify_otp"
  ui_component?: string; // e.g., "date_picker", "form_login"
}
```

### 4.2 Real-time Monitoring & Feedback
Latency (1-3s) is expected. We must keep the user engaged.

- **States**:
  1. `status: 'typing'` -> Agent is generating tokens (standard dots).
  2. `status: 'processing'` -> Agent is executing tools/guidelines (Show "Analyzing...", "Checking Database...").
- **Implementation**:
  - Listen for `status` events from Parlant.
  - If `data.status === 'processing'`, allow specific "Thought Chain" visuals (optional, for transparency).

### 4.3 Human Handoff Protocol
Seamless transition to a human agent is critical for complex queries.

- **Trigger**: Special `status` event or specific `message` metadata `handoff: true`.
- **UI Transition**:
  - **Visuals**: Change Avatar from "Bot" to "Human Support".
  - **Input**: Disable "AI Features" (e.g., auto-suggest).
  - ** Routing**: The `useParlantSession` hook should detect this flag and potentially pause the Parlant polling loop if the handoff moves to a Live Chat WebSocket, OR keep polling if the human replies via the Parlant API.
- **Protocol**:
  1. Agent: "I'm connecting you with a specialist." -> emits `handoff_requested`.
  2. UI: Shows "Connecting..." spinner.
  3. System: Connects to Zendesk/Intercom.
  4. System: Emits `handoff_connected`.
  5. UI: Updates header to "Chatting with {Name}".

## 5. Accessibility & Compliance (A11y)

### 5.1 Screen Readers (Live Regions)
Incoming messages from the agent must be announced without stealing focus.
- **Implementation**: A visually hidden `div` with `aria-live="polite"` and `aria-atomic="true"`.
- **Behavior**: Copy incoming agent message text into this div. "Polite" waits for user to pause typing.

### 5.2 Keyboard Navigation
- **Focus Trap**: Not required for main chat, but Focus Management is key.
- **Return Focus**: If connection drops and reconnects, ensure focus isn't lost from the input field.

## 6. Testing & Observability

### 6.1 SDK Mocking Strategy
Avoid testing implementation details of `parlant-client`. Mock the *responses* using Vitest.

**Factory Pattern for Mocks**:
```typescript
import { vi } from 'vitest';

vi.mock('../../lib/parlant-adapter', () => {
  return {
    ParlantAdapter: vi.fn().mockImplementation(() => ({
      getEvents: vi.fn(), 
      sendMessage: vi.fn().mockResolvedValue({}),
    }))
  };
});
```

### 5.2 Error Boundary & Degradation
- **Component Error Boundary**: Wrap `MessageList` to catch Markdown rendering errors.
- **Graceful Degradation**:
  - If polling fails critically, switch UI to "Offline Mode" (Read-only access to history).

## 7. Deliverables

### 6.1 Strict TypeScript Interfaces

```typescript
// Custom User Interface (Client App-side)
export interface ChatUser {
  id: string; // Maps to 'customerId' in Parlant
  name: string;
  avatarUrl?: string;
}

export interface Message {
  id: string; // UUID (client-gen) or Server ID
  source: 'customer' | 'agent' | 'system';
  content: string; 
  timestamp: number;
  status: 'sending' | 'sent' | 'delivered' | 'error';
}

export type ConnectionStatus = 'IDLE' | 'CONNECTING' | 'CONNECTED' | 'RECONNECTING' | 'ERROR';
```

### 6.2 Implementation Plan Logic
*Note: The actual implementation must utilize `AbortController` and recursive timeouts for React Strict Mode compatibility.*

```typescript
// Inside useParlantSession
useEffect(() => {
  const controller = new AbortController();
  const isPolling = useRef(false);
  let timeoutId: NodeJS.Timeout;

  const poll = async () => {
    // Prevent double-execution in Strict Mode or race conditions
    if (isPolling.current || controller.signal.aborted) return;
    
    isPolling.current = true;
    
    try {
      const events = await adapter.getEvents(offsetRef.current, controller.signal);
      processEvents(events); // Update Offset & State
      
      // Reset retry count on success
      retryRef.current = 0; 
      
      // Immediate loop if data received, else slight delay
      timeoutId = setTimeout(poll, events.length > 0 ? 0 : 100);
      
    } catch (err) {
       if (err.name === 'AbortError') return;
       
       // Backoff Logic
       const delay = Math.min(1000 * Math.pow(1.5, retryRef.current++), 30000);
       timeoutId = setTimeout(poll, delay);
    } finally {
       isPolling.current = false;
    }
  };
  
  // Kickoff
  void poll();

  return () => { 
    controller.abort();
    clearTimeout(timeoutId);
  };
}, [sid]);
```

### 6.3 Risk Assessment ("Footguns")

1.  **Session & Auth**: Docs imply open access via `agentId`.
    *   *Risk*: Malicious users spamming session creation.
    *   *Mitigation*: Server-side proxy for session creation is recommended in production (hide `ParlantClient` init from public bundle if possible, though custom frontend usually implies public client). If strictly client-side, implement Rate Limiting on the API Gateway / Load Balancer.

2.  **Deduplication Race Conditions**:
    *   *Risk*: "Optimistic" message remains "sending" forever if the heuristic match fails (e.g., slight text modification by server?).
    *   *Mitigation*: Implement a "Time-out" sweep. If an optimistic message is > 30s old and unmatched, mark as `sent` (assume delivered but unmatched) or `error` to prompt user.

3.  **Markdown Injection**:
    *   *Mitigation*: `rehype-sanitize` MUST be configured with a strict allow-list. Deny `script`, `iframe`, `object`, `embed`, `style`.

---
**End of Design Document**
