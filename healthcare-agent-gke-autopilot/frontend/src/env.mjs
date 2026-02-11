import { createEnv } from "@t3-oss/env-nextjs"
import { z } from "zod"

export const env = createEnv({
  server: {
    ANALYZE: z
      .enum(["true", "false"])
      .optional()
      .transform((value) => value === "true"),
  },
  client: {
    NEXT_PUBLIC_PARLANT_API_URL: z.string().url(),
    NEXT_PUBLIC_AGENT_ID: z.string().min(1),
    NEXT_PUBLIC_PARLANT_AUTH_TOKEN: z.string().optional(),
  },
  runtimeEnv: {
    ANALYZE: process.env.ANALYZE,
    NEXT_PUBLIC_PARLANT_API_URL: process.env.NEXT_PUBLIC_PARLANT_API_URL,
    NEXT_PUBLIC_AGENT_ID: process.env.NEXT_PUBLIC_AGENT_ID,
    NEXT_PUBLIC_PARLANT_AUTH_TOKEN: process.env.NEXT_PUBLIC_PARLANT_AUTH_TOKEN,
  },
})
