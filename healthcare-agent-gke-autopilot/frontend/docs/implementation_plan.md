# Implementation Plan: Custom Parlant Frontend

**Target Directory:** `healthcare-agent-gke-autopilot/frontend`
**Template:** Blazity/next-enterprise
**Architecture:** REST Adapter (No SDK Dependency) + Copy-Own UI

## User Review Required
> [!IMPORTANT]
> **Dependency Source:** We will enforce a "Copy-Own" strategy for `shadcn-chat`. This means we will NOT install it via npm. We will manually create the component files (`src/components/ui/chat/*`) based on the source code to ensure React 19 compatibility.

## Proposed Changes

### Phase 1: Initialization & Cleanup
#### [NEW] [Project Scaffold]
- Initialize Next.js 15+ project using the Blazity enterprise template.
- **Command:** `npx create-next-app@latest healthcare-agent-gke-autopilot/frontend -e https://github.com/Blazity/next-enterprise`
- **Cleanup:** 
  - Remove `terraform/` directory (Cloud bloat).
  - Remove `.github/workflows` (We will use our own or GKE specific ones).

#### [NEW] [.env.local.example](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/frontend/.env.local.example)
- Define strictly required environment variables:
  ```bash
  NEXT_PUBLIC_PARLANT_API_URL=http://localhost:8080 # Output of kubectl port-forward
  NEXT_PUBLIC_AGENT_ID=your-agent-id
  NEXT_PUBLIC_PARLANT_AUTH_TOKEN=your-jwt-token # Required if connecting to protected backend
  ```

#### [MODIFY] [next.config.mjs](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/frontend/next.config.mjs)
- **Proxy Configuration**: Add `rewrites()` to handle CORS if hitting the Agent directly from client.
  ```javascript
  async rewrites() {
    return [
      {
        source: '/api/parlant/:path*',
        destination: `${process.env.NEXT_PUBLIC_PARLANT_API_URL}/:path*`
      }
    ]
  }
  ```

### Phase 2: Core Architecture (The "SDK" Layer)
#### [NEW] [src/lib/parlant-sdk.ts](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/frontend/src/lib/parlant-sdk.ts)
- Implement `ParlantAdapter` class.
- **Constructor**: Accepts `agentId`, `baseUrl`, and optional `authToken`.
- **`createSession(customerId?)`**: Initiates a new session with the backend. returns `sessionId`.
- **`getEvents(sessionId, minOffset)`**: Polls for new events for a specific session.
- **`sendMessage(sessionId, message)`**: Sends a user message to the session.
- **Type Safety**: Uses Zod schemas to validate API responses. Updates `ParlantEventSchema` to include `ai_agent` source and IDs.
#### [NEW] [src/hooks/use-parlant.ts](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/frontend/src/hooks/use-parlant.ts)
- Implement `useParlantSession` hook.
- **Logic**:
  - `AbortController` integration for strict mode safety.
  - Recursive `setTimeout` polling loop.
  - State management for `messages` and `connectionStatus`.

### Phase 3: UI Implementation ("Copy-Own" Strategy)
#### [NEW] [src/components/ui/chat](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/frontend/src/components/ui/chat)
- Manually scaffold the Chat Interface components (derived from `shadcn-chat` but owned by us):
  - `chat-bubble.tsx`: Message rendering (User vs Agent).
  - `chat-input.tsx`: Textarea with auto-resize.
  - `chat-list.tsx`: Scrollable container with auto-scroll logic.
- **Dependencies**: Install `lucide-react`, `react-markdown`, `rehype-sanitize`, `clsx`, `tailwind-merge`.

#### [NEW] [src/components/parlant-chat.tsx](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/frontend/src/components/parlant-chat.tsx)
- Composition layer connecting `useParlantSession` with the UI components.
- Implement "Journeys" visualization and "Human Handoff" UI states.

### Phase 4: Testing & Configuration
#### [MODIFY] [tsconfig.json](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/frontend/tsconfig.json)
- **Path Aliases**: Ensure TypeScript solves the alias used in tests (consistency).
  ```json
  "paths": {
    "parlant-client": ["./src/lib/parlant-sdk.ts"]
  }
  ```

#### [MODIFY] [vitest.config.ts](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/frontend/vitest.config.ts)
- **Alias Configuration**:
  ```typescript
  alias: {
    'parlant-client': '<rootDir>/src/lib/parlant-sdk.ts' // Map "client" imports to our Adapter
  }
  ```
- ensure `setupFiles` are correctly pointing to the test environment.
### Phase 5: Production Hardening (GKE Ready)
#### [NEW] [Dockerfile](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/frontend/Dockerfile)
- Create a multi-stage Dockerfile optimized for Next.js Standalone output.
- **Key Features**:
  - `deps` stage: Install dependencies (cache mount).
  - `builder` stage: `npm run build` with `output: 'standalone'` in `next.config.mjs`.
  - `runner` stage: Alpine node image, non-root user (`node`), copy `.next/standalone`.

#### [NEW] [src/env.mjs](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/frontend/src/env.mjs)
- Implement `t3-oss/env-nextjs` (or Zod validation) to strictly validate env vars at runtime/build time.
- **Fail Fast**: Build should fail if `NEXT_PUBLIC_PARLANT_API_URL` is missing.

#### [MODIFY] [src/components/ui/chat/chat-list.tsx](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/frontend/src/components/ui/chat/chat-list.tsx)
- **Accessibility**: Ensure the "Assistant is typing" indicator and new messages are wrapped in a strictly compliant `aria-live` region.
- **Error Boundary**: Wrap the chat interface in a client-side `<ErrorBoundary>` to catch Markdown rendering crashes.

#### [MODIFY] [next.config.mjs](file:///home/limcheekin/dev/ws/py/production-deployment/healthcare-agent-gke-autopilot/frontend/next.config.mjs)
- **Standalone Output**:
  ```javascript
  const nextConfig = {
    output: 'standalone',
    // ... existing rewrites
  };
  ```
## Verification Plan

### Automated Tests
- **Unit Tests**:
  - Run `npm test` (Vitest).
  - Verify `ParlantAdapter` mocks work via the alias.
  - Test `useParlantSession` hook for:
    - Polling backoff.
    - Abort signal handling (no memory leaks).
    - Deduplication logic.

### Manual Verification
- **Dev Server**: Run `npm run dev`.
- **Flow**:
  1. Open Chat -> Check "Connection Established".
  2. Send "Hello" -> Verify Optimistic Update (Immediate gray bubble).
  3. Wait -> Verify Agent Response (markdown rendering).
  4. Network Tab -> Confirm `GET /events` long-polling loop with `30s` timeout.
  5. Close Tab/Component -> Verify polling stops (Abort).
