"use client";

import { Activity, Wifi, WifiOff } from "lucide-react";
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
    const isConnecting = status === "connecting";

    return (
        <div className={cn(
            "flex flex-col bg-white rounded-2xl shadow-lg shadow-primary/5 border border-healthcare-border overflow-hidden",
            className
        )}>
            {/* Chat Header */}
            <div className="flex items-center justify-between px-5 py-3.5 bg-gradient-to-r from-primary to-primary-dark">
                <div className="flex items-center gap-3">
                    <div className="relative">
                        <div className="flex items-center justify-center w-9 h-9 rounded-full bg-white/20 backdrop-blur-sm">
                            <Activity className="w-4.5 h-4.5 text-white" />
                        </div>
                        {/* Status Dot */}
                        <span className={cn(
                            "absolute -bottom-0.5 -right-0.5 w-3 h-3 rounded-full border-2 border-primary",
                            isConnected && "bg-accent",
                            isConnecting && "bg-yellow-400",
                            isError && "bg-healthcare-error"
                        )}>
                            {isConnected && (
                                <span className="absolute inset-0 rounded-full bg-accent animate-pulse-ring" />
                            )}
                        </span>
                    </div>
                    <div>
                        <h2 className="text-sm font-heading font-semibold text-white">
                            Health Assistant
                        </h2>
                        <p className="text-[11px] text-white/70">
                            {isError ? "Connection lost" : isConnected ? "Online • Ready to help" : "Connecting..."}
                        </p>
                    </div>
                </div>

                {/* Connection Badge */}
                <div className={cn(
                    "flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[11px] font-medium",
                    isConnected && "bg-white/15 text-white/90",
                    isConnecting && "bg-yellow-400/20 text-yellow-100",
                    isError && "bg-red-400/20 text-red-100"
                )}>
                    {isError ? (
                        <><WifiOff className="w-3 h-3" /> Offline</>
                    ) : isConnected ? (
                        <><Wifi className="w-3 h-3" /> Connected</>
                    ) : (
                        <><Wifi className="w-3 h-3 animate-pulse" /> Connecting</>
                    )}
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
            <div className="p-4 border-t border-healthcare-border-subtle bg-healthcare-surface-alt/50">
                <ChatInput
                    placeholder="Ask a health question..."
                    onSend={sendMessage}
                    disabled={isConnecting}
                />
                {isError && (
                    <div className="flex items-center gap-2 mt-2 px-1">
                        <div className="w-1.5 h-1.5 rounded-full bg-healthcare-error animate-pulse" />
                        <p className="text-xs text-healthcare-error">
                            Connection issue detected. Attempting to reconnect...
                        </p>
                    </div>
                )}
            </div>
        </div>
    );
}
