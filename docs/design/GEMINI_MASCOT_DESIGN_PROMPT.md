# Gemini prompt: design Corenyth's emotional ghost

You are implementing the VISUAL DESIGN of an existing Flutter ghost mascot. Its conversation interpretation, shared mood state, and transition plumbing already exist. Use them. Do not replace them or add another emotion detector. Implement the design in code; a description or mockup alone does not complete this task.

## Workspace and files — read these first

Repository root: `/Users/kawaiii_neko/Documents/GitHub/Corenyth`

1. **Primary file to edit:** `/Users/kawaiii_neko/Documents/GitHub/Corenyth/lib/ui/ghost_mascot.dart`
   - `GhostMascot` is the reusable widget (`size`, `animated`).
   - `_GhostMascotState` owns float/gaze timing and a separate 650 ms expression transition.
   - `_GhostPainter.paint(Canvas canvas, Size size)` currently draws the neutral ghost. This is where the emotional visual design belongs.
   - `_GhostPainter.expression()` returns the already blended `MascotExpressionFrame`. It is deliberately wired but not yet used for visual changes.
   - Repaint already listens to both the float clock and the expression transition.
2. **Read-only state contract:** `/Users/kawaiii_neko/Documents/GitHub/Corenyth/lib/ui/mascot_emotion_scope.dart`
   - `MascotEmotionScope.of(context)` supplies the active target.
   - `MascotExpressionFrame.weight(MascotMood mood)` returns each mood's current blend weight, 0–1.
   - `MascotExpressionFrame.intensity` is a 0–1 expressive strength.
   - Weights sum to approximately 1, and interrupted transitions retain their current blend instead of snapping.
3. **Read-only classification logic:** `/Users/kawaiii_neko/Documents/GitHub/Corenyth/lib/mascot/mascot_emotion.dart`
   - `MascotMood`: `calm`, `happy`, `excited`, `supportive`, `concerned`, `curious`.
   - `MascotEmotion` holds `mood` and `intensity`.
   - `MascotEmotionInterpreter` replays the last eight user messages with emotional continuity. Sadness maps to supportive; serious/anxious context maps to concerned. The classifier is a conservative English heuristic, not an LLM.
4. **Read-only integration:** `/Users/kawaiii_neko/Documents/GitHub/Corenyth/lib/main.dart`
   - `_AssistantHomeState` scopes the header's emotion; resets it when switching chats.
   - `ChatPage` publishes mood on history load/refresh and user submission through `onEmotionChanged`.
5. **Read-only placements:**
   - `/Users/kawaiii_neko/Documents/GitHub/Corenyth/lib/ui/app_shell.dart`: header, `GhostMascot(size: 30, animated: false)`.
   - `/Users/kawaiii_neko/Documents/GitHub/Corenyth/lib/ui/chat_view.dart`: welcome, `size: 132`; assistant message labels, `size: 18, animated: false`. ChatView also scopes emotion from its transcript for standalone use.
   - `animated: false` disables continuous floating, blinking and gaze tracking. Emotional still poses and finite transitions must still work. Do not start endless animation in the small placements.
6. **Palette:** `/Users/kawaiii_neko/Documents/GitHub/Corenyth/lib/theme/app_colors.dart`.
7. **Tests:**
   - `/Users/kawaiii_neko/Documents/GitHub/Corenyth/test/ghost_mascot_test.dart`
   - `/Users/kawaiii_neko/Documents/GitHub/Corenyth/test/mascot_emotion_test.dart`
   - `/Users/kawaiii_neko/Documents/GitHub/Corenyth/test/chat_view_test.dart`
   - `/Users/kawaiii_neko/Documents/GitHub/Corenyth/test/app_shell_test.dart`
8. **Original visual reference, read only:** `/Users/kawaiii_neko/Documents/GitHub/TeriBehenKaPortfolio/src/components/ui/shader-svg.tsx`. Blink CSS is in that project's `src/styles/global.css`.

## User's design direction

The ghost is a warm companion: supportive during sadness or serious discussion, expressive and playful during happiness. Keep the recognizable rounded ghost silhouette with scalloped feet and flowing pink/blue/lavender gradient. Express emotion through EYES, POSTURE, MOVEMENT and SUBTLE COLOR SHIFTS. Do not add a mouth. Avoid text labels, mood badges, UI controls, or diagnostic details in the product.

Design six distinct but coherent expressions:

- **calm:** relaxed open eyes, natural blinking, soft colors, familiar gentle float. This is the default when interpretation is uncertain.
- **happy:** visibly delighted eyes, a small friendly tilt, brighter warm highlights and a buoyant float. Readable without exaggerated motion.
- **excited:** the most playful state: joyful eye shapes, stronger but restrained buoyancy, squash/stretch and warm glow. If adding a celebratory bounce, trigger it once on entering excitement, never on every repaint, stream token, or rebuild. No particles or constant flashing.
- **supportive:** sadness in the conversation should make the ghost comforting and present. Softer attentive eyes, sympathetic tilt, slower float, gentle color shifts. Do not depict crying, despair or dramatic drooping.
- **concerned:** composed, focused eyes; steadier posture and subdued motion. Seriousness should feel reassuring, never panicked, angry, alarmist or playful.
- **curious:** attentive eyes with subtle asymmetry, an inquisitive tilt and small searching motions. Avoid making it look judgmental or confused.

## Implement against the existing contract

At the start of `paint`, read `final frame = expression();`. Blend visual parameters using `frame.weight(MascotMood.happy)`, etc. Multiply appropriate ranges by `frame.intensity`. Do not select a single dominant mood with a switch: doing so discards the smooth transition plumbing. Use weighted blends of eye geometry, tilt, float amplitude/speed, stretch and palette. Keep animation phase continuous when moods change; do not reset the main clock on each mood update.

Keep eye tracking additive to the emotional eye pose, bounded inside the silhouette. Preserve natural blink behavior. Make poses distinguishable at header size (30) and assistant-label size (18), with expressive detail at welcome size (132). Respect existing layout dimensions, avoid clipping at animation extremes, and keep reading/composing unobstructed.

Respect `_GhostPainter.animated`: false means no continuous motion. Respect reduced motion: no floating, blinking, oscillating gradients, gaze movement or celebratory bounce; show the target emotion as a static eye/posture/color pose. The existing expression controller snaps to the target when reduced motion is enabled. Do not undo that behavior. Hidden tabs use TickerMode; do not introduce timers that continue animating offscreen.

Keep everything native Flutter Canvas/CustomPainter, offline, dependency-free and efficient. Do not add a WebView, backend, model calls, external assets or new packages. Keep the current semantic mascot label and emotional value. Keep the existing public constructor and expression/state APIs compatible.

## Ownership and boundaries

Own the visual rendering in `lib/ui/ghost_mascot.dart`, plus visual test coverage as needed. If visual helpers are necessary, place them beside it with explicit imports. Do not modify the interpreter, chat routing, assistant responses, memory/task logic, model inference, shared scope contract, or emotion timing policy. Do not edit the portfolio repository. Existing unrelated working-tree changes must be preserved.

## Verification and delivery

Run from the repository root:

```sh
flutter analyze
flutter test test/mascot_emotion_test.dart test/ghost_mascot_test.dart test/chat_view_test.dart test/app_shell_test.dart
flutter test
```

Add meaningful visual checks for all six expressions, mixed transitions, tiny sizes and reduced motion. Use bounded pumps for continuously animated scenes. Do not weaken the existing transition/interpreter tests. Render a six-state preview at a fixed animation phase so the user can compare expressions, and inspect it for clipping, unreadable eyes and insufficient contrast.

Deliver the actual Flutter design implementation, a preview of all six states, and a concise account of changed files and validation. The final result should make emotion visible without changing the conversation-to-emotion logic.
