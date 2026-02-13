import { SendHorizonal } from "lucide-react";
import * as React from "react";

import { cn } from "@/lib/utils";

export interface ChatInputProps
    extends React.TextareaHTMLAttributes<HTMLTextAreaElement> {
    onSend?: (message: string) => void;
}

export const ChatInput = React.forwardRef<HTMLTextAreaElement, ChatInputProps>(
    ({ className, onSend, onKeyDown, disabled, ...props }, ref) => {
        const [value, setValue] = React.useState("");
        const textareaRef = React.useRef<HTMLTextAreaElement | null>(null);

        const canSend = value.trim().length > 0 && !disabled;

        const handleSend = () => {
            if (canSend && onSend) {
                onSend(value.trim());
                setValue("");
                // Reset textarea height
                if (textareaRef.current) {
                    textareaRef.current.style.height = "auto";
                }
            }
        };

        const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
            if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                handleSend();
            }
            if (onKeyDown) onKeyDown(e);
        };

        const handleChange = (e: React.ChangeEvent<HTMLTextAreaElement>) => {
            setValue(e.target.value);
            // Auto-resize
            const textarea = e.target;
            textarea.style.height = "auto";
            textarea.style.height = `${Math.min(textarea.scrollHeight, 120)}px`;
        };

        // Merge refs
        const setRefs = React.useCallback(
            (node: HTMLTextAreaElement | null) => {
                textareaRef.current = node;
                if (typeof ref === "function") ref(node);
                else if (ref) (ref as React.MutableRefObject<HTMLTextAreaElement | null>).current = node;
            },
            [ref]
        );

        return (
            <div className={cn(
                "flex items-end gap-2 rounded-xl border border-healthcare-border bg-white p-1.5 transition-all duration-200",
                "focus-within:border-primary focus-within:ring-2 focus-within:ring-primary/20",
                disabled && "opacity-60 cursor-not-allowed",
                className
            )}>
                <textarea
                    ref={setRefs}
                    rows={1}
                    value={value}
                    onChange={handleChange}
                    onKeyDown={handleKeyDown}
                    disabled={disabled}
                    className={cn(
                        "flex-1 min-h-[40px] max-h-[120px] resize-none bg-transparent px-3 py-2 text-sm",
                        "placeholder:text-healthcare-text-muted/60 focus:outline-none",
                        "disabled:cursor-not-allowed"
                    )}
                    {...props}
                />
                <button
                    type="button"
                    onClick={handleSend}
                    disabled={!canSend}
                    aria-label="Send message"
                    className={cn(
                        "flex items-center justify-center w-10 h-10 rounded-lg shrink-0",
                        "transition-all duration-200 cursor-pointer",
                        canSend
                            ? "bg-primary text-white hover:bg-primary-dark shadow-md shadow-primary/25 active:scale-95"
                            : "bg-healthcare-border-subtle text-healthcare-text-muted/40 cursor-not-allowed"
                    )}
                >
                    <SendHorizonal className="w-4.5 h-4.5" />
                </button>
            </div>
        );
    }
);
ChatInput.displayName = "ChatInput";
