# orbit

a little buddy that lives on your mac.

Orbit sits next to your cursor. Hold **⌃ control + ⌥ option** anywhere and ask a question out loud. When you let go, Orbit looks at your screen, answers out loud, and draws on top of whatever you're using: it highlights buttons, circles things, draws arrows, and sketches in a notes app.

![orbit](app/screenshots/welcome.png)
![drawing overlay](app/screenshots/overlay.png)
![settings](app/screenshots/settings.png)

## What it does
- **Cursor buddy**: a small orb follows your mouse across every screen.
- **Push to talk**: hold ⌃⌥, speak, then let go. Speech is recognized on device when your Mac supports it.
- **Sees your screen**: each message includes a screenshot of the display under your cursor. You can turn this off with "sees screen".
- **Points and draws**: replies can include drawing tags (`POINT`, `BOX`, `CIRCLE`, `ARROW`, `LINE`, `PATH`, `TEXT`). Orbit animates them over your screen as if drawn with a pen.
- **Chats**: past conversations are listed in a sidebar, like other AI apps.
- **Settings**: buddy behavior, how long drawings stay, dictation languages, keyboard shortcuts, and permission status.
- **Custom shortcuts**: change the talk shortcut (modifiers alone or modifiers + key), "clear drawings" (default ⌃⌘K), and "open orbit" (default ⌃⌘O).
- **Many languages**: choose several dictation languages and flip between them with the language button next to talk.
- **Your choice of AI**: your ChatGPT (Codex CLI) or Claude (Claude Code) subscription, any OpenAI-compatible API, or a local Ollama model.

## Build
Requires macOS 14.2+ and Swift 5.10+.

```bash
cd app
./scripts/build.sh
open dist/Orbit.app
```

`build.sh` signs with your Apple Development certificate when you have one, so macOS keeps Orbit's permissions across rebuilds. An ad-hoc signature changes on every build, and macOS then quietly drops those permissions.

On first use, macOS asks for Screen Recording, Microphone, and Speech Recognition permissions. The ⌃⌥ hotkey also needs Accessibility permission, which you grant from the "allow the hotkey" link in the app.

## Design
See [app/DESIGN.md](app/DESIGN.md) for the design system.

## Credits
Inspired by [Clicky](https://github.com/farzaa/clicky) by Farza (MIT). Orbit is an independent app and is not affiliated with HeyClicky.
