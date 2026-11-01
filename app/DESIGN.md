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

## Drawing on the screen
Everything Orbit draws is in one ink, the colour picked in Settings (blue `#3380FF` by default, or red, gold, green),
with a soft glow of the same colour (65%, about a 12pt blur). No white underlay.

- **Pen**: an even 3.5pt line with round ends; underlines and strikes 3pt. Strokes draw in order, each over a time
  that grows with its length, and the buddy holds the pen tip.
- **Labels**: a small pastel gel capsule (lighter at the top, white gloss strip, dark rim) with 12pt semibold
  near-black words and no tail. Placed beside the mark on the first free spot (above, below, right, left, then
  corners and further out), never on another label or mark, always on screen. They pop in once the mark is drawn.
- **Frames**: a dashed outline (8 on, 5 off) with a 7% tint; a pill for wide short things, small rounded corners
  otherwise.
- **Rings**: one loop that runs a little past where it started, slightly uneven like a hand.
- **Handwriting**: Patrick Hand (bundled, OFL); Nanum Pen for Korean when the Mac has it, Noteworthy as the fallback. White on dark screens,
  near-black on light ones, read from the screenshot under the words.
- **Badges, ticks, crosses, highlighter, sticky notes**: badges are small gel coins; the highlighter is a 26% band of
  ink; sticky notes are butter-yellow paper tilted −2° with a folded corner and a strip of tape in the light gel
  tone, used only for explanations on empty space.
- **Click targets**: a solid 3.5pt ring with the glow, 4pt off the control, moved onto the control's real frame when
  Accessibility finds one about the size the model drew. A pill for wide short controls, and a ripple that grows 9pt
  on every side every 1.4s. It stays up while Orbit waits: a click inside it (4pt slop), or for a hover target the
  pointer resting 0.6s, ticks, and the next step is asked for once the app has had 0.7s to react.
- **Spotlight**: everything dims to 42% black except a soft-edged opening (7pt blur) 10pt around one thing.
- **Cheer**: a kaomoji on a 15pt gel pill; ten twinkles fly off its edge and fade within a second.
- **Walkthrough bar**: a silver capsule at the top centre of the screen, or the bottom when the top would cover the
  control: the step number on a gel coin, the task in 13pt semibold, what Orbit waits for in 11pt, an aqua
  **next step** pill for steps Orbit can't see finish, and × to stop. It takes clicks without taking focus.
- **Sound**: a quiet pen scratch while drawing, a pop when a label lands, a tap for a sticky note, a ping for a click
  target, a soft sweep as a spotlight dims, a tick when the click lands, a little chime for a cheer, a sweep on clear.
  All synthesized; can be turned off in Settings.
