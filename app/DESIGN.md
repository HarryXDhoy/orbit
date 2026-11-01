# Orbit design system

Lives in `Sources/Orbit/DesignSystem.swift` under `DS`. Every view pulls its colors, type and components from there.

The look is a bright retro desktop: a soft gray canvas with a dot grid, glossy aqua and silver pills, tiny Mac windows with traffic lights, speech bubbles, kaomoji, and all-lowercase copy.

## Tokens
| token | value | use |
|---|---|---|
| `canvas` | `#F5F5F5` | window background, under the dot grid |
| `surface` | white | cards, composer, window bodies |
| `ink` / `ink2` / `ink3` | black at 100% / 55% / 35% | text levels |
| `hairline` | black at 8% | dividers, field borders |
| `link` | `#2F7CF6` | text buttons ("new chat") |
| `aqua` | `#EDF4FF → #D6E7FF → #A2C7FF → #99CBF8 → #A2D2F7`, edge `#221898` | primary pill, your bubbles, the active state |
| `silver` | `#FBFBFB → #EDEDED → #E4E4E4`, edge `#626262` | secondary pill, buddy bubbles |
| shadow | black at 12%, y 10, blur 24 | floating things |
| edge width | 0.7pt | pill and bubble outlines |

Type uses the system font (SF): display 56 medium, title 20 medium, body 14, label 13, caption 11.

## Components
- `PillButtonStyle(kind: .aqua | .silver | .ghost, compact:)`: the glossy pill buttons
- `PillToggleStyle`: a toggle drawn as a pill with a status dot (aqua when on)
- `LinkButtonStyle`, `IconButtonStyle`: text links and small icon buttons
- `DotGrid`: the dotted canvas
- `MacWindow(title:highlighted:)`: a mini window with traffic lights and a filename-style title
- `SpeechBubble(mine:)`: a bubble with a tail (aqua for you, silver for orbit)
- `Waveform(active:)`: the listening and thinking meter
- `DSField`, `StatusPill`, `OrbitMark`

## Rules
- Copy is lowercase, except for proper names inside sentences (macOS, CLI).
- There is one aqua element per area: the main action.
- Orbit uses its own name and its own mark. HeyClicky's logo and wordmark are never used.
