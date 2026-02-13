import "styles/tailwind.css"
import type { Metadata } from "next"

export const metadata: Metadata = {
  title: "Healthcare Agent - AI Health Assistant",
  description: "Get reliable health information and guidance from our AI-powered healthcare assistant.",
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
      </head>
      <body className="min-h-screen bg-healthcare-bg text-healthcare-text antialiased" suppressHydrationWarning>
        {children}
      </body>
    </html>
  )
}
