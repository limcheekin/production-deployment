import * as React from "react";
import { cn } from "@/lib/utils";

export interface ChatInputProps
    extends React.TextareaHTMLAttributes<HTMLTextAreaElement> {
    onSend?: (message: string) => void;
}

export const ChatInput = React.forwardRef<HTMLTextAreaElement, ChatInputProps>(
    ({ className, onSend, onKeyDown, ...props }, ref) => {
        const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
            if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                if (onSend && e.currentTarget.value.trim()) {
                    onSend(e.currentTarget.value.trim());
                    e.currentTarget.value = "";
                }
            }
            if (onKeyDown) onKeyDown(e);
        };

        return (
            <textarea
                ref={ref}
                className={cn(
                    "flex min-h-[60px] w-full rounded-md border border-input bg-background px-3 py-2 text-sm ring-offset-background placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50",
                    className
                )}
                onKeyDown={handleKeyDown}
                {...props}
            />
        );
    }
);
ChatInput.displayName = "ChatInput";
