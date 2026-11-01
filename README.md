# orbit

a little buddy that lives on your mac.

Orbit sits next to your cursor. Hold **⌃ control + ⌥ option** anywhere and ask a question out loud. When you let go, Orbit looks at your screen, answers out loud, and draws on top of whatever you're using: it highlights buttons, circles things, draws arrows, and sketches in a notes app.

![orbit](app/screenshots/welcome.png)
![drawing overlay](app/screenshots/overlay.png)

## What it does
- **Cursor buddy**: a small orb follows your mouse across every screen.
- **Push to talk**: hold ⌃⌥, speak, then let go. Speech is recognized on device when your Mac supports it.
- **Sees your screen**: each message includes a screenshot of the display under your cursor. You can turn this off with "sees screen".
- **Points and draws**: replies can include drawing tags (`POINT`, `BOX`, `CIRCLE`, `ARROW`, `LINE`, `PATH`, `TEXT`). Orbit animates them over your screen as if drawn with a pen.
- **Your choice of AI**: your ChatGPT (Codex CLI) or Claude (Claude Code) subscription, any OpenAI-compatible API, or a local Ollama model.

## Build
Requires macOS 14.2+ and Swift 5.10+.

```bash
cd app
./scripts/build.sh
open dist/Orbit.app
```

On first use, macOS asks for Screen Recording, Microphone, and Speech Recognition permissions. The ⌃⌥ hotkey also needs Accessibility permission, which you grant from the "allow the hotkey" link in the app.

## Design
See [app/DESIGN.md](app/DESIGN.md) for the design system.

## Credits
Inspired by [Clicky](https://github.com/farzaa/clicky) by Farza (MIT). Orbit is an independent app and is not affiliated with HeyClicky.
