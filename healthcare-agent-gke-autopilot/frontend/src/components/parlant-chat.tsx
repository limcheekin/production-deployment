"use client";

import React from "react";
import { useParlantSession } from "@/hooks/use-parlant";
import { cn } from "@/lib/utils";
import { ErrorBoundary } from "./error-boundary";
import { ChatInput } from "./ui/chat/chat-input";
import { ChatList } from "./ui/chat/chat-list";

export function ParlantChat({ className }: { className?: string }) {
    const { messages, sendMessage, status, agentStatus } = useParlantSession();

    const isConnected = status === "connected";
    const isError = status === "error";

    return (
        <div className={cn("flex flex-col h-[600px] w-full max-w-2xl border rounded-lg shadow-sm bg-background", className)}>
            {/* Header */}
            <div className="flex items-center justify-between px-4 py-3 border-b">
                <div className="flex items-center gap-2">
                    <div className={cn("w-2 h-2 rounded-full", {
                        "bg-green-500": isConnected,
                        "bg-yellow-500": status === "connecting",
                        "bg-red-500": isError
                    })} />
                    <span className="font-semibold text-sm">Parlant Agent</span>
                </div>
                <div className="text-xs text-muted-foreground">
                    {isError ? "Connection Error" : isConnected ? "Online" : "Connecting..."}
                </div>
            </div>

            <ErrorBoundary>
                {/* Message List */}
                <ChatList
                    messages={messages}
                    isTyping={agentStatus === "typing"}
                    className="flex-1"
                />
            </ErrorBoundary>

            {/* Input Area */}
            <div className="p-4 border-t">
                <ChatInput
                    placeholder="Type a message..."
                    onSend={sendMessage}
                    disabled={status === "connecting"} // Allow retry on error? Maybe not disable on error to let user try again?
                // actually if error, maybe show retry button. But for now, simple disable on connecting.
                />
                {isError && (
                    <p className="text-xs text-red-500 mt-2">
                        Network issues detected. Trying to reconnect...
                    </p>
                )}
            </div>
        </div>
    );
}
