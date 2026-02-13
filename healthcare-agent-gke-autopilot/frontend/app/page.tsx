import { ShieldCheck, Stethoscope } from "lucide-react";

import { ParlantChat } from "@/components/parlant-chat";

export default function Web() {
  return (
    <div className="flex flex-col min-h-screen">
      {/* Top Header Bar */}
      <header className="bg-white/80 backdrop-blur-sm border-b border-healthcare-border sticky top-0 z-10">
        <div className="max-w-4xl mx-auto px-4 py-3 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="flex items-center justify-center w-10 h-10 rounded-xl bg-primary/10">
              <Stethoscope className="w-5 h-5 text-primary" />
            </div>
            <div>
              <h1 className="text-lg font-heading font-semibold text-healthcare-text">
                Healthcare Agent
              </h1>
              <p className="text-xs text-healthcare-text-muted">
                AI-Powered Health Assistant
              </p>
            </div>
          </div>
          <div className="flex items-center gap-1.5 text-xs text-healthcare-text-muted">
            <ShieldCheck className="w-4 h-4 text-accent" />
            <span className="hidden sm:inline">Secure & Private</span>
          </div>
        </div>
      </header>

      {/* Chat Area */}
      <main className="flex-1 flex flex-col items-center justify-center p-4">
        <ParlantChat className="w-full max-w-4xl flex-1" />
      </main>
    </div>
  )
}
