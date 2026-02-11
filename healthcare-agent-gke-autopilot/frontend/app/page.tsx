import { ParlantChat } from "@/components/parlant-chat";

export default function Web() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center p-4 bg-gray-50 dark:bg-gray-900">
      <h1 className="text-3xl font-bold mb-8 text-foreground">Healthcare Agent</h1>
      <ParlantChat />
    </main>
  )
}
