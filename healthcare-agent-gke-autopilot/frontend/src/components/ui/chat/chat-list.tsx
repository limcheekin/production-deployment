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
            scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
        }
    }, [messages, isTyping, shouldAutoScroll]);

    const handleScroll = () => {
        if (!scrollRef.current) return;
        const { scrollTop, scrollHeight, clientHeight } = scrollRef.current;
        // If user scrolls up, disable auto-scroll
        const isAtBottom = scrollHeight - scrollTop - clientHeight < 50;
        setShouldAutoScroll(isAtBottom);
    };

    return (
        <div
            ref={scrollRef}
            onScroll={handleScroll}
            className={cn("flex-1 overflow-y-auto p-4 space-y-4", className)}
            {...props}
            role="log"
            aria-live="polite"
            aria-relevant="additions"
        >
            {messages.map((message) => (
                <ChatBubble
                    key={message.id}
                    role={message.role === "assistant" ? "assistant" : "user"} // Map strict types
                    content={message.content}
                    status={message.status}
                />
            ))}

            {isTyping && (
                <div className="flex w-full items-start gap-2 p-4">
                    <div className="flex h-8 w-8 shrink-0 select-none items-center justify-center rounded-md border shadow bg-muted">
                        <span className="animate-pulse">...</span>
                    </div>
                    <div className="bg-muted rounded-lg px-3 py-2 text-sm text-muted-foreground">
                        Agent is typing...
                    </div>
                </div>
            )}
        </div>
    );
}
