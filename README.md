# orbit

a little buddy that lives on your mac.

Orbit sits next to your cursor. Hold **⌃ control + ⌥ option** anywhere and ask a question out loud. When you let go, Orbit looks at your screen, answers out loud, and draws on top of whatever you're using: it highlights buttons, circles things, draws arrows, and sketches in a notes app.

![orbit](app/screenshots/welcome.png)
![drawing overlay](app/screenshots/overlay.png)
![settings](app/screenshots/settings.png)
![3d model](app/screenshots/model3d.png)

## What it does
- **Cursor buddy**: a small orb follows your mouse across every screen.
- **Push to talk**: hold ⌃⌥, speak, then let go. Speech is recognized on device when your Mac supports it.
- **Sees your screen**: each message includes a screenshot of the display under your cursor. You can turn this off with "sees screen".
- **Pick an area**: the "area" button in the composer lets you drag over part of the screen, like ⌘⇧4, so Orbit looks at just that part. A click takes the whole screen; Esc cancels.
- **Points and draws**: replies can include drawing tags (`POINT`, `BOX`, `CIRCLE`, `ARROW`, `LINE`, `UNDERLINE`, `HIGHLIGHT`, `NUM`, `CHECK`, `CROSS`, `PATH`, `TEXT`, `NOTE`). Orbit draws them over your screen with a glowing pen in your chosen ink, names things in small gel labels that never overlap, writes in handwriting that stays readable on dark and light screens, and pins sticky notes for explanations. Soft pen and pop sounds go with it.
- **Builds 3D models**: ask for something in 3D and Orbit builds a small model next to your cursor from simple shapes (`MODEL` and `PART` tags), one piece at a time, then slowly turns it. Rendered natively with SceneKit.
- **Chats**: past conversations are listed in a sidebar, like other AI apps.
- **Type from anywhere**: press ⌃⌘T in any app and a small box opens next to your cursor. Type, press return, and Orbit answers in its bubble and draws. The shortcut can also be modifiers alone, like ⌃⌘, which open the box with a quick tap.
- **Bubble follows the buddy**: near the right or bottom edge of the screen, the reply bubble opens on the other side, and its tail always points back at the buddy.
- **Settings**: buddy behavior, how long drawings stay, dictation languages, keyboard shortcuts, and permission status.
- **Custom shortcuts**: change the talk shortcut (modifiers alone or modifiers + key), "type to orbit" (default ⌃⌘T), "clear drawings" (default ⌃⌘K), and "open orbit" (default ⌃⌘O).
- **Many languages**: choose several dictation languages and flip between them with the language button next to talk, or pick **auto**. Auto listens in up to three of your languages at once and keeps the one you actually spoke.
- **Your choice of AI**: your ChatGPT (Codex CLI) or Claude (Claude Code) subscription, any OpenAI-compatible API, or a local Ollama model.
- **Connectors**: turn on connectors you already set up in Claude Code (Gmail, Google Calendar, Drive and others from claude.ai) or Codex (`codex mcp list`), and Orbit can use those apps to answer. Each connector is look-only until you allow changes. Orbit loads only the connectors you turn on, without your Claude Code hooks.
- **Model list**: Orbit asks each connection which models it offers (`codex debug models`, the API's `/models`, Ollama's installed models) and lists them in Connections and next to the composer. Claude Code has no list command, so Orbit shows its aliases (fable, opus, sonnet, haiku).

## Build
Requires macOS 14.2+ and Swift 5.10+.

```bash
cd app
./scripts/build.sh
open dist/Orbit.app
```

`build.sh` signs with your Apple Development certificate when you have one, so macOS keeps Orbit's permissions across rebuilds. An ad-hoc signature changes on every build, and macOS then quietly drops those permissions.

On first use, macOS asks for Screen Recording, Microphone, and Speech Recognition permissions. The ⌃⌥ hotkey also needs Accessibility permission, which you grant from the "allow the hotkey" link in the app.

If System Settings shows Orbit turned on but Orbit still says "not allowed", the saved entry belongs to an older build. Use **reset & ask again** in Settings → permissions, turn Orbit on in the list that opens, then relaunch Orbit.

## Design
See [app/DESIGN.md](app/DESIGN.md) for the design system.

## Credits
Inspired by [Clicky](https://github.com/farzaa/clicky) by Farza (MIT). Orbit is an independent app and is not affiliated with HeyClicky.

Handwriting is set in [Patrick Hand](https://fonts.google.com/specimen/Patrick+Hand) by Patrick Wagesreiter, licensed under the SIL Open Font License 1.1 (`app/Resources/Fonts/PatrickHand-OFL.txt`).
