import { Stethoscope, User } from "lucide-react";
import * as React from "react";
import ReactMarkdown from "react-markdown";
import rehypeSanitize from "rehype-sanitize";

import { cn } from "@/lib/utils";

export interface ChatBubbleProps extends React.HTMLAttributes<HTMLDivElement> {
    role: "user" | "assistant" | "system";
    content: string;
    status?: "sending" | "sent" | "delivered" | "error";
}

export function ChatBubble({ role, content, status, className, ...props }: ChatBubbleProps) {
    const isUser = role === "user";

    return (
        <div
            className={cn(
                "flex w-full items-end gap-2.5 animate-fade-in-up",
                isUser ? "flex-row-reverse" : "flex-row",
                className
            )}
            {...props}
        >
            {/* Avatar */}
            <div
                className={cn(
                    "flex h-8 w-8 shrink-0 select-none items-center justify-center rounded-full transition-colors duration-200",
                    isUser
                        ? "bg-primary text-white"
                        : "bg-primary/10 text-primary"
                )}
            >
                {isUser ? <User className="h-4 w-4" /> : <Stethoscope className="h-4 w-4" />}
            </div>

            {/* Bubble */}
            <div
                className={cn(
                    "flex max-w-[75%] flex-col gap-1 rounded-2xl px-4 py-2.5 text-sm relative transition-all duration-200",
                    isUser
                        ? "bg-primary text-white rounded-br-md"
                        : "bg-healthcare-surface-alt border border-healthcare-border text-healthcare-text rounded-bl-md"
                )}
            >
                {/* Role label */}
                <span className={cn(
                    "text-[10px] font-medium uppercase tracking-wider mb-0.5",
                    isUser ? "text-white/60" : "text-healthcare-text-muted"
                )}>
                    {isUser ? "You" : "Health Assistant"}
                </span>

                {/* Content */}
                {isUser ? (
                    <p className="whitespace-pre-wrap leading-relaxed">{content}</p>
                ) : (
                    <div className="markdown-content">
                        <ReactMarkdown rehypePlugins={[rehypeSanitize]}>
                            {content}
                        </ReactMarkdown>
                    </div>
                )}

                {/* Status indicator */}
                {status === "sending" && (
                    <span className="text-[10px] opacity-60 mt-0.5 self-end">Sending...</span>
                )}
                {status === "error" && (
                    <span className="text-[10px] text-healthcare-error mt-0.5 self-end font-medium">
                        Failed to send
                    </span>
                )}
            </div>
        </div>
    );
}
