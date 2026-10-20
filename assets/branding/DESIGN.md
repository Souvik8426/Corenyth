---
name: Ethereal Arcana
colors:
  surface: '#141218'
  surface-dim: '#141218'
  surface-bright: '#3b383f'
  surface-container-lowest: '#0f0d13'
  surface-container-low: '#1d1b21'
  surface-container: '#211f25'
  surface-container-high: '#2b292f'
  surface-container-highest: '#36343a'
  on-surface: '#e7e0e9'
  on-surface-variant: '#cac4d0'
  inverse-surface: '#e7e0e9'
  inverse-on-surface: '#322f36'
  outline: '#948f9a'
  outline-variant: '#49454f'
  surface-tint: '#d0bcff'
  primary: '#d4c2ff'
  on-primary: '#36265f'
  primary-container: '#b9a6e8'
  on-primary-container: '#493973'
  inverse-primary: '#655590'
  secondary: '#e6c182'
  on-secondary: '#422d00'
  secondary-container: '#5c420e'
  on-secondary-container: '#d4b072'
  tertiary: '#eec0ca'
  on-tertiary: '#452830'
  tertiary-container: '#d0a5af'
  on-tertiary-container: '#5a3a42'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#e9ddff'
  primary-fixed-dim: '#d0bcff'
  on-primary-fixed: '#210f49'
  on-primary-fixed-variant: '#4d3d77'
  secondary-fixed: '#ffdea8'
  secondary-fixed-dim: '#e6c182'
  on-secondary-fixed: '#271900'
  on-secondary-fixed-variant: '#5c420e'
  tertiary-fixed: '#ffd9e1'
  tertiary-fixed-dim: '#e8bbc5'
  on-tertiary-fixed: '#2d131b'
  on-tertiary-fixed-variant: '#5e3e46'
  background: '#141218'
  on-background: '#e7e0e9'
  surface-variant: '#36343a'
typography:
  display-lg:
    fontFamily: Plus Jakarta Sans
    fontSize: 36px
    fontWeight: '600'
    lineHeight: 44px
    letterSpacing: -0.03em
  display-lg-mobile:
    fontFamily: Plus Jakarta Sans
    fontSize: 28px
    fontWeight: '600'
    lineHeight: 36px
    letterSpacing: -0.025em
  headline-lg:
    fontFamily: Plus Jakarta Sans
    fontSize: 30px
    fontWeight: '600'
    lineHeight: 38px
    letterSpacing: -0.02em
  headline-lg-mobile:
    fontFamily: Plus Jakarta Sans
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
    letterSpacing: -0.02em
  headline-md:
    fontFamily: Plus Jakarta Sans
    fontSize: 20px
    fontWeight: '500'
    lineHeight: 28px
    letterSpacing: -0.015em
  headline-sm:
    fontFamily: Plus Jakarta Sans
    fontSize: 17px
    fontWeight: '600'
    lineHeight: 24px
    letterSpacing: -0.01em
  body-lg:
    fontFamily: Plus Jakarta Sans
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 26px
    letterSpacing: -0.005em
  body-md:
    fontFamily: Plus Jakarta Sans
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 22px
    letterSpacing: 0em
  body-sm:
    fontFamily: Plus Jakarta Sans
    fontSize: 12px
    fontWeight: '400'
    lineHeight: 18px
    letterSpacing: 0.01em
  label-lg:
    fontFamily: Plus Jakarta Sans
    fontSize: 14px
    fontWeight: '600'
    lineHeight: 18px
    letterSpacing: 0.02em
  label-md:
    fontFamily: Plus Jakarta Sans
    fontSize: 12px
    fontWeight: '500'
    lineHeight: 16px
    letterSpacing: 0.03em
  label-sm:
    fontFamily: Plus Jakarta Sans
    fontSize: 10px
    fontWeight: '600'
    lineHeight: 14px
    letterSpacing: 0.06em
rounded:
  sm: 0.5rem
  DEFAULT: 1rem
  md: 1.5rem
  lg: 2rem
  xl: 3rem
  full: 9999px
spacing:
  gutter: 1rem
  margin: 1rem
  space-xs: 0.25rem
  space-sm: 0.5rem
  space-md: 1rem
  space-lg: 1.5rem
  space-xl: 2rem
---

## Brand & Style

The design system embodies a mystical tech aesthetic: an intimate, cerebral, and contemplative sanctuary where advanced artificial intelligence meets esoteric elegance. Engineered for mindful personal organization, deep chat inquiry, memory curation, and task choreography, the atmosphere evokes ancient astrological observatories distilled through hyper-precise contemporary software.

The aesthetic fuses deep black-space minimalism with crystalline glassmorphism. Subtle spectral luminosity replaces loud, flat digital interfaces. Interactions feel quiet, deliberate, and weightless—designed to instill calm clarity, intuitive wonder, and focus rather than digital exhaustion.

## Colors

The palette relies on absolute darkness punctured by ethereal light:

- **Canvas & Background:** Absolute pitch black (`#000000`). It maximizes OLED contrast and serves as the empty cosmos for illuminated interface modules.
- **Surfaces & Containers:** Near-black with a subtle astral-violet cast (`#121016`). Elevated interactive containers and floating sheets transition into `#1C1922`.
- **Typography:** Primary text is warm Ivory (`#F3ECDD`) to prevent optical fatigue. Secondary metadata, timestamps, and placeholders utilize Muted Amethyst (`#A9A3B5`).
- **Luminescence & Accents:**
  - **Lavender Accent (`#B9A6E8`):** The primary kinetic signal used for interactive states, active indicators, and focus boundaries.
  - **Core Astral Aura:** A dual-tone gradient running from `#CDBBFF` (luminous violet) to `#BFE9FF` (pale cyan), reserved for AI cognition states, floating speech orb avatars, and resonant focus glow rings.
  - **Soft Gold (`#D4B072`):** A secondary accent used selectively for milestone badges, priority stars, memory pins, and hairline ornamental rules.
  - **Blush (`#F2C4CE`):** Applied to conversational pings, micro-tags, and unread notifications.
  - **Functional Feedback:** Calibrated to soft, organic hues—Success Mint (`#9FD8B8`) and Cautionary Rose (`#E8838F`).

## Typography

The type system prioritizes balanced optical geometry and airy rhythm. Set in **Plus Jakarta Sans**, its geometric counters and contemporary proportions ground the app's mystical narrative with crisp ergonomic legibility.

- **Headlines & Display:** Tightly tracked headings (-0.02em to -0.03em) anchor titles with quiet confidence.
- **Body Text:** Generous line heights (1.5x to 1.625x) prevent dense message clustering across lengthy conversational turns, stream-of-consciousness memory logs, and nested task checklists.
- **Labels & Micro-copy:** Uppercase or small-scale badge tokens leverage expanded letter-spacing (up to 0.06em) to provide sharp hierarchy against deep black backdrops.

## Layout & Spacing

A mobile-first, single-column viewport architecture that expands gracefully into multi-pane workspace panels for tablets and foldable form factors.

- **Mobile Viewport (< 600px):** Single-column layout anchored with a 16px (`1rem`) outer safe margin and a persistent floating pill navigation dock. Chat threads and memory cascades stream in an unbroken vertical rhythm with strict safe-area insets at top and bottom.
- **Tablet / Large Handheld (600px - 1024px):** Dual-surface split. Chat dialogue or memory streams reside in a primary canvas spanning 60% of viewport width, accompanied by an auxiliary sliding utility drawer (tasks, calendar cues, and contextual insights) on the remaining 40%. Margins scale to 24px (`1.5rem`).
- **Internal Spacing Cadence:** Built around an 8-point harmonic grid:
  - Micro-gaps (`space-xs` to `space-sm`) structure metadata clusters, badge insets, and message reaction pills.
  - Component padding (`space-md` to `space-lg`) bounds cards, sheets, and modal frames, maintaining comfortable negative space around tactile touch targets.
  - Structural separators (`space-xl`) define macro-shifts between conversational days, memory milestones, and distinct task groups.

## Elevation & Depth

Depth in this system is conveyed not through heavy drop shadows, but through luminous dissipation, tonal layering, and glassy translucence:

- **Surface Stratification:**
  - **Level 0 (Base):** Solid `#000000`. The absolute foundation.
  - **Level 1 (Cards, Chat Bubbles, Memory Blocks):** `#121016` rendered at 80% opacity with a `24px` backdrop blur (`backdrop-filter: blur(24px)`). Outlined by a 1px ghost border set to `rgba(185, 166, 232, 0.12)`.
  - **Level 2 (Modals, Overlays, Input Dock):** `#1C1922` at 90% opacity with a `32px` backdrop blur, framed by a 1px border of `rgba(205, 187, 255, 0.20)`.
- **Ethereal Ambient Glows:**
  - AI thinking, floating action buttons, and active tabs emit subtle, highly diffused radial glows: `0 0 32px rgba(185, 166, 232, 0.18)` and `0 0 64px rgba(191, 233, 255, 0.08)`.
  - Focused interactive elements display an inner hairline luminescence: `inset 0 1px 0 rgba(255, 255, 255, 0.15)`.

## Shapes

The interface embraces organic, pill-forward silhouettes that soften technical complexity and impart a tactile, talismanic feel:

- **Pill Primitives:** Buttons, filter chips, audio wave visualizers, bottom navigation docks, and prompt pills utilize full circular radiuses (capsule geometry).
- **Cards & Sheet Surfaces:** Content panels, bottom modal drawers, and memory snapshot frames use generous radii (`1.5rem` to `2rem`), yielding smooth, pebble-like contours that nest naturally against mobile screen bezels.
- **Form Controls:** Text inputs and interactive toggles follow pure pill structures (`rounded-full`), maintaining tactile comfort under thumb reach.

## Components

### Buttons & Interactive Controls
- **Primary Kinetic Button:** Capsule shape filled with Lavender (`#B9A6E8`), text styled in dark `#121016` (`label-lg`), illuminated on press with a subtle cyan ambient aura.
- **Ghost / Glass Button:** Semi-transparent fill (`rgba(28, 25, 34, 0.6)`), 1px border in `rgba(185, 166, 232, 0.25)`, text in Ivory (`#F3ECDD`).
- **Icon Action Buttons:** Circular (`44px x 44px`) minimal tap targets with glass backing, elevating on hover/focus with a radial shimmer.

### Navigation & Segmented Tabs
- **Floating Astral Dock:** A floating pill navigation bar resting above the bottom home indicator. Frosted `#121016` surface, containing icons for *Chat*, *Tasks*, and *Memories*.
- **Active Tab Pill:** Marked by an internal Lavender capsule glow with Ivory iconography, while inactive destinations rest at Muted Amethyst (`#A9A3B5`) with zero background fill.

### Input Fields & Prompt Composer
- **Conversational Omnibar:** A persistent capsule docked at the bottom, layered in `#1C1922` with a 1px perimeter border of `rgba(185, 166, 232, 0.18)`.
- **Active State:** The border smoothly transitions to a glowing gradient (`#CDBBFF` to `#BFE9FF`), accompanied by an inner hairline highlight.
- **Action Icons:** Microphone, file attachment, and astral submit triggers sit integrated inside the composer flanks.

### Cards & Surfaces
- **Chat Bubbles:**
  - *User Bubble:* Compact pill-card aligned right, rendered in `#1C1922` with Ivory typography.
  - *AI Assistant Bubble:* Aligned left, framed in translucent `#121016` with a delicate gradient boundary and optional micro-orb signature in the corner.
- **Memory Shards:** Curated media/thought cards featuring a hairline gold divider (`#D4B072` at 30% opacity), date tags styled in `label-sm`, and a glass overlay that reveals playback controls on tap.
- **Task Cards:** Surface-level modules with rounded-2xl frames. Incomplete items feature an unfilled circular ring that transitions to a Soft Gold or Mint fill upon completion with subtle strikethrough typography transitions.

### Chips & Badges
- **Contextual Filter Chips:** Small pill capsules (`px-3 py-1`) using Muted Amethyst outlines, transitioning into soft Blush (`#F2C4CE`) or Lavender backgrounds when selected.
- **Status & Priority Badges:** High-priority items carry an illuminated Soft Gold dot indicator alongside micro-labeled text (`label-sm`).

### AI Ambient Orb
- A continuous, floating interactive sphere rendered with a dynamic mesh gradient (`#CDBBFF` blending into `#BFE9FF`). It rhythmically pulses during speech synthesis and expands into radial particle waves when processing context.