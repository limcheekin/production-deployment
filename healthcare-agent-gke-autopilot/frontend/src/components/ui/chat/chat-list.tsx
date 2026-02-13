import { MessageCircle, Stethoscope } from "lucide-react";
import * as React from "react";

import { type ChatMessage } from "@/hooks/use-parlant";
import { cn } from "@/lib/utils";
import { ChatBubble } from "./chat-bubble";

interface ChatListProps extends React.HTMLAttributes<HTMLDivElement> {
    messages: ChatMessage[];
    isTyping?: boolean;
}

export function ChatList({ messages, isTyping, className, ...props }: ChatListProps) {
    const scrollRef = React.useRef<HTMLDivElement>(null);
    const [shouldAutoScroll, setShouldAutoScroll] = React.useState(true);

    // Scroll to bottom on new messages if shouldAutoScroll is true
    React.useEffect(() => {
        if (shouldAutoScroll && scrollRef.current) {
            scrollRef.current.scrollTo({
                top: scrollRef.current.scrollHeight,
                behavior: "smooth",
            });
        }
    }, [messages, isTyping, shouldAutoScroll]);

    const handleScroll = () => {
        if (!scrollRef.current) return;
        const { scrollTop, scrollHeight, clientHeight } = scrollRef.current;
        const isAtBottom = scrollHeight - scrollTop - clientHeight < 50;
        setShouldAutoScroll(isAtBottom);
    };

    const isEmpty = messages.length === 0 && !isTyping;

    return (
        <div
            ref={scrollRef}
            onScroll={handleScroll}
            className={cn("flex-1 overflow-y-auto scroll-smooth", className)}
            {...props}
            role="log"
            aria-live="polite"
            aria-relevant="additions"
        >
            {/* Empty State */}
            {isEmpty && (
                <div className="flex flex-col items-center justify-center h-full px-6 py-12 text-center animate-fade-in-up">
                    <div className="flex items-center justify-center w-16 h-16 rounded-2xl bg-primary/10 mb-5">
                        <Stethoscope className="w-8 h-8 text-primary" />
                    </div>
                    <h3 className="text-lg font-heading font-semibold text-healthcare-text mb-2">
                        Welcome to Health Assistant
                    </h3>
                    <p className="text-sm text-healthcare-text-muted max-w-sm leading-relaxed">
                        Ask me about symptoms, medications, wellness tips, or general health information. I&apos;m here to help.
                    </p>
                    <div className="flex flex-wrap gap-2 mt-6 justify-center">
                        {["What are common cold symptoms?", "Tips for better sleep", "How to reduce stress?"].map((suggestion) => (
                            <span
                                key={suggestion}
                                className="px-3 py-1.5 text-xs rounded-full bg-primary/5 text-primary border border-primary/15 cursor-default"
                            >
                                <MessageCircle className="w-3 h-3 inline mr-1.5 -mt-0.5" />
                                {suggestion}
                            </span>
                        ))}
                    </div>
                </div>
            )}

            {/* Messages */}
            {!isEmpty && (
                <div className="p-4 space-y-4">
                    {messages.map((message) => (
                        <ChatBubble
                            key={message.id}
                            role={message.role === "assistant" ? "assistant" : "user"}
                            content={message.content}
                            status={message.status}
                        />
                    ))}

                    {/* Typing Indicator */}
                    {isTyping && (
                        <div className="flex items-end gap-2.5 animate-fade-in-up">
                            <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary">
                                <Stethoscope className="h-4 w-4" />
                            </div>
                            <div className="bg-healthcare-surface-alt border border-healthcare-border rounded-2xl rounded-bl-md px-4 py-3">
                                <div className="flex items-center gap-1">
                                    <span className="w-2 h-2 rounded-full bg-primary/60 animate-bounce-dot" style={{ animationDelay: "0s" }} />
                                    <span className="w-2 h-2 rounded-full bg-primary/60 animate-bounce-dot" style={{ animationDelay: "0.16s" }} />
                                    <span className="w-2 h-2 rounded-full bg-primary/60 animate-bounce-dot" style={{ animationDelay: "0.32s" }} />
                                </div>
                            </div>
                        </div>
                    )}
                </div>
            )}
        </div>
    );
}
