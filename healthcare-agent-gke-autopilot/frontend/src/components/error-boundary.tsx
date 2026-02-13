"use client";

import { AlertTriangle, RotateCcw } from "lucide-react";
import React, { Component, ErrorInfo, ReactNode } from "react";

interface Props {
    children?: ReactNode;
    fallback?: ReactNode;
}

interface State {
    hasError: boolean;
}

export class ErrorBoundary extends Component<Props, State> {
    public state: State = {
        hasError: false,
    };

    public static getDerivedStateFromError(_: Error): State {
        return { hasError: true };
    }

    public componentDidCatch(error: Error, errorInfo: ErrorInfo) {
        console.error("Uncaught error:", error, errorInfo);
    }

    public render() {
        if (this.state.hasError) {
            if (this.props.fallback) {
                return this.props.fallback;
            }
            return (
                <div className="flex flex-col items-center justify-center p-8 text-center animate-fade-in-up">
                    <div className="flex items-center justify-center w-14 h-14 rounded-2xl bg-healthcare-error/10 mb-4">
                        <AlertTriangle className="w-7 h-7 text-healthcare-error" />
                    </div>
                    <h2 className="text-base font-heading font-semibold text-healthcare-text mb-1">
                        Something went wrong
                    </h2>
                    <p className="text-sm text-healthcare-text-muted mb-5 max-w-xs">
                        The chat interface encountered an unexpected error. Please try again.
                    </p>
                    <button
                        className="inline-flex items-center gap-2 px-4 py-2 text-sm font-medium rounded-lg bg-primary text-white hover:bg-primary-dark transition-colors duration-200 cursor-pointer active:scale-95 focus:outline-none focus:ring-2 focus:ring-primary/40 focus:ring-offset-2"
                        onClick={() => this.setState({ hasError: false })}
                    >
                        <RotateCcw className="w-4 h-4" />
                        Try Again
                    </button>
                </div>
            );
        }

        return this.props.children;
    }
}
