import { useCallback, useEffect, useRef, useState } from "react";
import { env } from "@/env.mjs";
import { ParlantAdapter, type ParlantEvent } from "parlant-client";

export interface ChatMessage {
    id: string; // dedup key
    role: "user" | "assistant" | "system";
    content: string;
    status: "sending" | "sent" | "delivered" | "error";
    timestamp: number;
}

export type ConnectionStatus = "connected" | "disconnected" | "error" | "connecting";

export function useParlantSession() {
    const [messages, setMessages] = useState<ChatMessage[]>([]);
    const [status, setStatus] = useState<ConnectionStatus>("connecting");
    const [agentStatus, setAgentStatus] = useState<"typing" | "processing" | "ready">("ready");

    const adapterRef = useRef<ParlantAdapter | null>(null);
    const offsetRef = useRef<number>(0);
    const subscriptionsRef = useRef<Map<string, () => void>>(new Map());

    const [sessionId, setSessionId] = useState<string | null>(null);

    // Initialize adapter and create session
    useEffect(() => {
        if (!env.NEXT_PUBLIC_AGENT_ID || !env.NEXT_PUBLIC_PARLANT_API_URL) {
            console.error("Missing Parlant configuration");
            setStatus("error");
            return;
        }

        const adapter = new ParlantAdapter(
            env.NEXT_PUBLIC_AGENT_ID,
            env.NEXT_PUBLIC_PARLANT_API_URL,
            env.NEXT_PUBLIC_PARLANT_AUTH_TOKEN
        );
        adapterRef.current = adapter;

        adapter.createSession()
            .then((id) => {
                setSessionId(id);
                // Status remains "connecting" until SSE connects
            })
            .catch((err) => {
                console.error("Failed to create session", err);
                setStatus("error");
            });

        return () => {
            // Cleanup logic if needed
        };
    }, []);

    // Helper to merge chunks into content
    const getMessageContent = (event: ParlantEvent): string => {
        if (event.message) return event.message;
        if (event.data?.chunks && Array.isArray(event.data.chunks)) {
            return event.data.chunks
                .filter(c => typeof c === 'string')
                .join("");
        }
        return "";
    };

    // Session Subscription
    useEffect(() => {
        const adapter = adapterRef.current;
        if (!adapter || !sessionId) return;

        setStatus("connected"); // Assume connected when we start

        const unsubscribeSession = adapter.subscribeToSession(
            sessionId,
            offsetRef.current,
            (event) => {
                // Update offset
                if (event.offset >= offsetRef.current) {
                    offsetRef.current = event.offset + 1;
                }

                if (event.kind === "status") {
                    const data = event.data as { type?: string };
                    if (data?.type === "typing") {
                        setAgentStatus("typing");
                    } else if (data?.type === "processing") {
                        setAgentStatus("processing");
                    } else {
                        setAgentStatus("ready");
                    }
                    return;
                }

                if (event.kind === "message") {
                    const eventId = event.id;
                    const role = event.source === "customer" || event.source === "customer_ui" ? "user" : "assistant";

                    // Update Messages State
                    setMessages((prev) => {
                        const existingIndex = prev.findIndex(m => m.id === `server-${eventId}`);
                        const content = getMessageContent(event);

                        // Handle User Messages (Optimistic Match)
                        if (role === 'user') {
                            const matchIndex = prev.findIndex(m =>
                                m.role === 'user' &&
                                m.status === 'sending' &&
                                m.content === content &&
                                Date.now() - m.timestamp < 10000
                            );

                            if (matchIndex !== -1 && existingIndex === -1) {
                                const newMessages = [...prev];
                                newMessages[matchIndex] = { ...newMessages[matchIndex], id: `server-${eventId}`, status: 'sent' };
                                return newMessages;
                            }
                        }

                        if (existingIndex !== -1) {
                            // Update existing message (e.g. status change or content update?)
                            // Usually main stream only sends initial, but let's be safe
                            const newMessages = [...prev];
                            newMessages[existingIndex] = { ...newMessages[existingIndex], content }; // Update content just in case
                            return newMessages;
                        } else {
                            // New Message
                            return [...prev, {
                                id: `server-${eventId}`,
                                role,
                                content,
                                status: "delivered",
                                timestamp: new Date(event.creation_utc || Date.now()).getTime()
                            }];
                        }
                    });

                    // Subscribe to AI Message Stream if new
                    if (event.source === "ai_agent" && !subscriptionsRef.current.has(eventId)) {
                        const unsub = adapter.subscribeToEvent(
                            sessionId,
                            eventId,
                            (updatedEvent) => {
                                const content = getMessageContent(updatedEvent);

                                setMessages(prev => {
                                    return prev.map(m => {
                                        if (m.id === `server-${eventId}`) {
                                            return { ...m, content };
                                        }
                                        return m;
                                    });
                                });

                                // Check for completion
                                const chunks = updatedEvent.data?.chunks as any[];
                                if (chunks && chunks.length > 0 && chunks[chunks.length - 1] === null) {
                                    // Unsubscribe
                                    unsub();
                                    subscriptionsRef.current.delete(eventId);
                                    setAgentStatus("ready");
                                }
                            },
                            (err) => {
                                console.error(`Error streaming message ${eventId}`, err);
                            }
                        );
                        subscriptionsRef.current.set(eventId, unsub);
                    }
                }
            },
            (error) => {
                console.error("Session SSE Error", error);
                // Optional: setStatus("error") if critical
            }
        );

        return () => {
            unsubscribeSession();
            // Cleanup all message subscriptions
            subscriptionsRef.current.forEach(unsub => unsub());
            subscriptionsRef.current.clear();
        };
    }, [sessionId]);

    const sendMessage = useCallback(async (text: string) => {
        if (!adapterRef.current || !sessionId) return;

        const adapter = adapterRef.current;
        const currentSessionId = sessionId;
        const tempId = `temp-${Date.now()}`;

        // Optimistic add
        setMessages(prev => [...prev, {
            id: tempId,
            role: "user",
            content: text,
            status: "sending",
            timestamp: Date.now()
        }]);

        try {
            await adapter.sendMessage(currentSessionId, text);
        } catch (err) {
            console.error("Send error", err);
            setMessages(prev => prev.map(m => m.id === tempId ? { ...m, status: "error" } : m));
        }
    }, [sessionId]);

    return { messages, sendMessage, status, agentStatus };
}
