# Healthcare Agent Frontend UI/UX Redesign

The current frontend is extremely bare-bones — a plain gray background with a basic bordered chat box using default Tailwind styles, no branding, and no visual polish. This redesign will transform it into a premium healthcare chat interface using a medical-grade design system.

## Design System

Generated via the UI/UX skill for healthcare:

| Token | Value | Purpose |
|-------|-------|---------|
| Primary | `#0891B2` (medical teal) | Headers, user bubbles, brand |
| Secondary | `#22D3EE` (cyan accent) | Highlights, hover states |
| CTA/Success | `#22C55E` (health green) | Send button, status indicators |
| Background | `#F0FDFA` (mint tint) | Page background |
| Text | `#134E4A` (dark teal) | Primary body text |
| Fonts | **Figtree** (headings) / **Noto Sans** (body) | Medical, clean, accessible |
| Style | Accessible & Ethical | WCAG AAA, high contrast, 16px+ |

## Proposed Changes

### Design Foundation

#### [MODIFY] [tailwind.css](file:///../../styles/tailwind.css)
- Add CSS custom properties (design tokens) for the healthcare color palette
- Define `--color-primary`, `--color-secondary`, `--color-accent`, `--color-background`, `--color-foreground`, `--color-muted`, etc.
- Import Google Fonts (Figtree + Noto Sans)
- Add base typography styles, smooth scrolling, and reduced-motion support
- Add utility classes for chat-specific elements (typing animation, fade-in)

#### [MODIFY] [layout.tsx](file:///../../app/layout.tsx)
- Add `<head>` metadata (title, description, charset, viewport)
- Add Google Fonts preconnect + link tags
- Apply design system body classes (font-family, bg color, text color, antialiasing)

---

### Page & Chat Container

#### [MODIFY] [page.tsx](file:///../../app/page.tsx)
- Full-screen chat layout (no more centered 600px box in a gray void)
- Add a branded top header bar with healthcare icon + title
- Chat component fills the viewport height below the header

#### [MODIFY] [parlant-chat.tsx](file:///../../src/components/parlant-chat.tsx)
- Redesign chat container with rounded corners, subtle shadow, glass-like card
- Redesign header with healthcare branding (Stethoscope icon), animated status dot, and styled agent name
- Improve connection status display with color-coded badges
- Redesign input area with a modern input bar layout (integrated send button)

---

### Chat Components

#### [MODIFY] [chat-bubble.tsx](file:///../../src/components/ui/chat/chat-bubble.tsx)
- User bubbles: primary teal gradient background, white text, right-aligned
- Assistant bubbles: white/light background with subtle border, left-aligned
- Improve avatar icons (Stethoscope for bot, User for human) with colored backgrounds
- Add timestamps, improved status indicators, and smooth fade-in animation
- Improve markdown content styling for assistant messages

#### [MODIFY] [chat-input.tsx](file:///../../src/components/ui/chat/chat-input.tsx)
- Replace bare textarea with a modern input row: rounded input field + circular send button
- Add send button with arrow icon (from Lucide)
- Visual feedback on typing (border highlight), disabled state styling
- Auto-resize behavior for multi-line input

#### [MODIFY] [chat-list.tsx](file:///../../src/components/ui/chat/chat-list.tsx)
- Add welcome/empty state with healthcare icon and greeting message
- Redesign typing indicator with animated dots (3 bouncing dots) instead of text "..."
- Smooth scroll behavior with CSS

---

### Error Handling

#### [MODIFY] [error-boundary.tsx](file:///../../src/components/error-boundary.tsx)
- Styled error card with warning icon, proper spacing, and a styled retry button

## Verification Plan

### Automated Tests

```bash
# Build verification (ensures no TypeScript or compile errors)
cd /../..
npm run build
```

### Manual Verification

- Open the app in a browser at `http://localhost:3000` and visually verify the redesigned interface
- Check responsive layout at different viewport sizes
