import { z } from "zod";

export type ParlantEvent = z.infer<typeof ParlantEventSchema>;

export const ParlantEventSchema = z.object({
    id: z.string(),
    creation_utc: z.string(),
    kind: z.enum(["message", "status", "tool"]),
    source: z.enum(["customer", "customer_ui", "human_agent", "human_agent_on_behalf_of_ai_agent", "ai_agent", "system"]),
    message: z.string().optional(),
    data: z.record(z.string(), z.unknown()).optional(),
    offset: z.number(),
});

export class ParlantClientError extends Error {
    constructor(message: string) {
        super(message);
        this.name = "ParlantClientError";
    }
}

export class ParlantServerError extends Error {
    constructor(message: string) {
        super(message);
        this.name = "ParlantServerError";
    }
}

export class ParlantAdapter {
    constructor(
        private agentId: string,
        private baseUrl: string,
        private authToken?: string
    ) { }

    async createSession(customerId?: string): Promise<string> {
        const url = `${this.baseUrl}/sessions`;
        const headers: HeadersInit = { "Content-Type": "application/json" };
        if (this.authToken) {
            headers["Authorization"] = `Bearer ${this.authToken}`;
        }

        const res = await fetch(url, {
            method: "POST",
            headers,
            body: JSON.stringify({
                agent_id: this.agentId,
                customer_id: customerId
            }),
        });

        if (!res.ok) {
            throw new ParlantServerError(res.statusText);
        }

        const data = await res.json() as { id: string };
        return data.id;
    }

    async getEvents(
        sessionId: string,
        minOffset: number,
        signal?: AbortSignal
    ): Promise<ParlantEvent[]> {
        const url = `${this.baseUrl}/sessions/${sessionId}/events?min_offset=${minOffset}&wait_for_data=10`;
        const headers: HeadersInit = { "Content-Type": "application/json" };
        if (this.authToken) {
            headers["Authorization"] = `Bearer ${this.authToken}`;
        }

        const res = await fetch(url, {
            signal,
            headers,
            cache: "no-store",
        });

        if (!res.ok) {
            if (res.status === 504) return []; // Timeout (long polling)
            if (res.status >= 400 && res.status < 500) {
                throw new ParlantClientError(res.statusText);
            }
            throw new ParlantServerError(res.statusText);
        }

        const data = await res.json();
        return z.array(ParlantEventSchema).parse(data);
    }

    async sendMessage(sessionId: string, message: string): Promise<void> {
        const url = `${this.baseUrl}/sessions/${sessionId}/events`;
        const headers: HeadersInit = { "Content-Type": "application/json" };
        if (this.authToken) {
            headers["Authorization"] = `Bearer ${this.authToken}`;
        }

        const res = await fetch(url, {
            method: "POST",
            headers,
            body: JSON.stringify({
                kind: "message",
                source: "customer",
                message,
            }),
        });

        if (!res.ok) {
            if (res.status >= 400 && res.status < 500) {
                throw new ParlantClientError(res.statusText);
            }
            throw new ParlantServerError(res.statusText);
        }
    }
    subscribeToSession(
        sessionId: string,
        minOffset: number,
        onEvent: (event: ParlantEvent) => void,
        onError: (error: Event) => void
    ): () => void {
        const url = new URL(`${this.baseUrl}/sessions/${sessionId}/events`);
        url.searchParams.set("min_offset", minOffset.toString());
        url.searchParams.set("wait_for_data", "60");
        url.searchParams.set("sse", "true");

        if (this.authToken) {
            url.searchParams.set("token", this.authToken);
        }

        const eventSource = new EventSource(url.toString());

        eventSource.onmessage = (event) => {
            try {
                const data = JSON.parse(event.data);
                const parsedEvent = ParlantEventSchema.parse(data);
                onEvent(parsedEvent);
            } catch (e) {
                console.error("Failed to parse SSE event", e);
            }
        };

        eventSource.onerror = (error) => {
            onError(error);
        };

        return () => {
            eventSource.close();
        };
    }

    subscribeToEvent(
        sessionId: string,
        eventId: string,
        onEvent: (event: ParlantEvent) => void,
        onError: (error: Event) => void
    ): () => void {
        const url = new URL(`${this.baseUrl}/sessions/${sessionId}/events/${eventId}`);
        url.searchParams.set("sse", "true");

        if (this.authToken) {
            url.searchParams.set("token", this.authToken);
        }

        const eventSource = new EventSource(url.toString());

        eventSource.onmessage = (event) => {
            try {
                const data = JSON.parse(event.data);
                const parsedEvent = ParlantEventSchema.parse(data);
                onEvent(parsedEvent);
            } catch (e) {
                console.error("Failed to parse SSE event", e);
            }
        };

        eventSource.onerror = (error) => {
            onError(error);
        };

        return () => {
            eventSource.close();
        };
    }
}
