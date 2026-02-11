import { Bot, User } from "lucide-react";
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
                "flex w-full items-start gap-2 p-4",
                isUser ? "flex-row-reverse" : "flex-row",
                className
            )}
            {...props}
        >
            <div
                className={cn(
                    "flex h-8 w-8 shrink-0 select-none items-center justify-center rounded-md border shadow",
                    isUser ? "bg-primary text-primary-foreground" : "bg-muted"
                )}
            >
                {isUser ? <User className="h-4 w-4" /> : <Bot className="h-4 w-4" />}
            </div>

            <div
                className={cn(
                    "flex max-w-[80%] flex-col gap-1 rounded-lg px-3 py-2 text-sm shadow-sm relative",
                    isUser
                        ? "bg-primary text-primary-foreground"
                        : "bg-muted text-foreground"
                )}
            >
                {isUser ? (
                    <p className="whitespace-pre-wrap leading-relaxed">{content}</p>
                ) : (
                    <div className="markdown-content prose prose-sm dark:prose-invert break-words">
                        <ReactMarkdown rehypePlugins={[rehypeSanitize]}>
                            {content}
                        </ReactMarkdown>
                    </div>
                )}

                {status === "sending" && (
                    <span className="text-[10px] opacity-70 absolute bottom-1 right-2">...</span>
                )}
                {status === "error" && (
                    <span className="text-[10px] text-red-500 absolute -bottom-4 right-0">Failed</span>
                )}
            </div>
        </div>
    );
}
