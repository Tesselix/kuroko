# Kuroko — Look and Controls

Oct 14, 2026 · @feral keep

## Purpose and notation

This document records how Kuroko looks and how its basic controls behave. It starts with color, borders, scrolling and keyboard navigation; other controls (buttons, toggles, text fields) will be added as they are discussed. It applies to the widget library and to the compositor's built-in UI.

It builds on the Human Factors reference, the Top-Level Design and the Widget Framework. Where they differ, the Top-Level Design wins.

**Defaults are parameters (agreed).** Every behavior described here is a default that can be changed through a parameter (see Widget Framework, Parameter precedence), unless changing it would contradict a fixed rule: the accessibility rules (flash limits, no state by color alone), the privacy rules, and the 0.1 s acknowledgement.

Notation:
- **(agreed)**: confirmed in discussion.
- **(suggestion)**: proposed, not yet confirmed.
- **(research)**: from published studies, listed under References.

## Look

### Direction (agreed)

- Calm, clean and professional. The inspiration is the principles of the macOS look: restrained color, thin lines, controls that stay out of the way.
- Principles, not appearance. Kuroko keeps its own visual identity.

### Accent color (agreed)

- **A calm blue is the default accent.**
- The accent is a **theme role**, not a fixed color. The library adapts it for light and dark themes and contrast, and the user can choose another accent.
- Blue stays distinguishable for the most common color vision deficiencies (red–green), which supports the accessibility scope.
- **Red stays reserved** for errors and the elevated-privilege window frame, so the accent never collides with them.
- Focus and selection always carry a shape cue as well (outline, check mark), never the blue tint alone.

### Borders (agreed)

- **Side and bottom borders are hairlines.** On HiDPI screens this can be one physical pixel (half a logical pixel at 2× scale).
- **The visible line and the grab area are separate.** A shared border between tiled windows looks like a hairline, while the area that reacts to the pointer is about 6–8 px wide. The pointer changes shape over it.
- **The bottom border keeps its status job:** a hairline at rest, growing to 3 px for progress, working and error states (see Top-Level Design, Window chrome).

## All widgets: hover enlargement (agreed)

Any widget with small text can be shown enlarged, floating over its own position, when the user rests on it. It helps users with weaker sight and everyone during tired hours.

### When it triggers

- **Only small text:** a widget is a candidate when its text is smaller than **15 logical pixels** (font size). Larger text is readable for most people and is never enlarged. The threshold is a parameter.
- **Hover:** the pointer **moved into** the widget and then rested (about 1 s, parameter). Content scrolling under a still pointer doesn't count, so a parked pointer never triggers it.
- **Focus:** keyboard focus landing on the widget, after the same dwell.
- **Dismissed** when the pointer moves out, on scroll, or on Escape.

### How it looks

- **Re-laid out, not magnified pixels:** the library draws the widget again at a larger font size, so text stays sharp.
- **Centered over the original,** clamped to the window and screen edges.
- **Grows and fades in** over 150–250 ms, never pops (epilepsy rule).
- **Password fields** enlarge as dots only.

### Rules

- **View-only:** the enlarged copy is a lens. Clicks and typing go to the real widget underneath, and the copy updates live.
- **The widget's own hover behavior wins:** the scrollbar's map, a tooltip and the fill helper replace enlargement on their widgets.
- **On by default.** It is an accessibility setting, at the top of the parameter precedence: the user controls it, and an app cannot turn it off. An app can only mark a widget as having its own hover behavior.
- (suggestion) **Time of day:** the user may set hours in which the dwell shortens or the threshold rises; later the agent may suggest this from the temporal context.
- (suggestion) **Other apps:** the compositor may later offer a plain pointer lens (bitmap zoom of the region under the pointer) for apps not built on the framework.

| Parameter | Default | Options |
| --- | --- | --- |
| Hover enlargement | On | On, off |
| Small-text threshold | 15 logical px | Size |
| Enlarged text size | (to tune) | Size |
| Dwell | About 1 s | Time |
| Triggers | Hover and focus | Hover, focus, both |

## Scrolling

### The problem

The scrollbar is one control asked to do three jobs, and today it is good at only one:

| Distance | Today | Problem |
| --- | --- | --- |
| A few lines | Wheel | Works well |
| A page to a few pages | Wheel | Tedious: many notches |
| Far | Dragging the thumb | Each pixel of thumb movement is many lines; the content moves too fast to recognize, so the user overshoots and hunts |

The hunting has two causes: the drag gain is fixed by document length, and the user cannot recognize the target while it is moving.

### Unit: lines (agreed)

- **A "line" is the line height of the default font in that window.**
- For text it is a real line. For images, drawings and maps it is the same distance, so one wheel notch feels the same everywhere.
- It scales with zoom and DPI. This is a design choice, not a research finding; the research below measures speed relative to the window as well (screen time and pages), not in pixels.

### The wheel (agreed)

Three inputs, three speed bands:

| Input | Movement | Screen time |
| --- | --- | --- |
| **Single notch** | About 3 lines, animated in under 0.1 s so it feels instant | Not limited: the user can read |
| **Continuous turning** | Accelerates through the bands below | |
| — fast band | Up to about 1.5 pages/s | About 0.9 s: headings and pictures stay recognizable |
| — very fast band | Up to about 2.7 pages/s, short bursts only | About 0.45 s: the upper limit of recognition |
| **Shift + turning** | Straight to the fast band | About 0.9 s |
| Beyond very fast | Use the document map | |

**Screen time** is how long content stays visible while it moves across the window. It adapts on its own to window height, font size and DPI.

Rules:
- **Slow is not slow.** Single notches move 3 lines with snappy animation, so jumping between lines stays quick. Acceleration starts only when notches come fast.
- **The fast band is capped.** Turning faster within it does not make content blur past; the cap is what keeps the user aware of where they are.
- **Very fast is for bursts** and eases back down afterwards so the eye can catch up.
- **One speed setting** scales all bands together, because people differ a lot.
- **Defaults lean toward comfortable,** not maximum values.

Research basis:
- (research) Wheel performance improves significantly with an acceleration algorithm (Hinckley et al. 2002).
- (research) Screen time is the general unit for scrolling speed. Measured at normal size while looking for headings and pictures: comfortable about 0.93 s on screen (about 1.5 pages/s), maximum tolerable about 0.44 s (about 2.7 pages/s). At one-third zoom the comfortable speed in pages per second roughly doubles. Recommended calibration: about 0.9 s at full size, 1.4 s at one-third (Wallace, Savage, Cockburn 2004).
- (research) Theoretical estimate in the same paper: an image needs about 450 ms on screen to be recognized, a short heading 550–950 ms to be read. Users familiar with a document recognize its pages by their layout shape.
- (research) Variation between people was large; participants were young, experienced, many of them gamers, so the general population likely tolerates less.
- (research) A three-segment transfer function (proportional, then capped at a visually trackable speed, then accelerated for long distances) is an established shape (US Patent 6856326). Scrolling transfer functions and their factors are analyzed in Quinn et al. 2012.

### Shift = run (agreed)

- Shift + wheel moves fast, like a running key in games.
- Where Kuroko solves a problem other desktops have, it overrides their conventions. Shift + wheel no longer means horizontal scrolling.
- (suggestion) One setting restores the old behavior for users who need it.

### Scrollbar (agreed)

- **Always visible and thin.**
- **Widens when the pointer approaches,** the same principle as the expanding window buttons: thin at rest, easy to grab when aimed at.
- Dragging the thumb still works.
- Hovering the scrollbar opens the document map (below).

### Document map (agreed)

A scaled-down view of the document that appears when the pointer rests near the scrollbar.

- **Fixed small scale, not "fit everything":** at most about 5 pages in the map's height, so each page is a recognizable block. Thin page separators group them for the eye. A shorter document fits entirely and the map does not move.
- **Structure stands out:** headings drawn bolder, images and tables as blocks, so prose has a shape too.
- **Sliding:** in the upper part of the map the pointer moves over a still map. Past about the middle, the map slides slowly, in proportion to the pointer, so the bottom of the track reaches the end of the document.
- **The map's position depends only on the pointer's position,** never on its history. The same pointer height always shows the same part of the document, so the hand learns it, and moving back returns exactly to the same place.
- **Magnifier:** a flat, undistorted box at the pointer's height, extending left over the content, showing a few readable lines. No fisheye distortion, which shifts the target as the pointer moves. (research) Fisheye menus tested slower than plain ones (Hornbæk and Hertzum 2007).
- **Section title:** the magnifier always shows the heading of the section it is in, in a small font at its top.
- **Click to jump:** the line under the pointer lands at the pointer's height in the content, so the eyes stay on the same spot. The jump is animated.
- **Overlay, don't resize:** the map slides in over the right edge of the content. It appears after the pointer rests about 80 ms, so passing by doesn't trigger it.
- **Cheap to draw:** lines as bars, headings as thicker bars, images as boxes, cached and redrawn only when the content changes.

### Viewport and center markers (agreed)

The map shows where the user is in the document, and the content shows where the eyes can rest.

- **Viewport marker:** two lines in the map bracketing the part of the document currently in view, with a faint band between them. It is the map's equivalent of the scrollbar thumb, drawn over the document's shape.
- **Center marker:** a line at the vertical middle of the window body, drawn in the content, aligned to the right next to the scrollbar. The same line appears in the map between the viewport lines, so the map shows which document line sits in the middle of the view.
- **Per window, not per screen.** Tiled windows have different heights and different middles.
- **Shape as well as color:** the viewport is a pair of lines with a band between them; the center marker is a single line ending in a small triangle at the scrollbar edge. Orange and green can look alike to people with red–green color vision deficiency, so the shapes carry the difference (no state by color alone).
- **Tied to the document:** when the map slides, and during an animated jump, both markers move with the document lines they mark, not with the map frame.
- **Fade, never blink** (epilepsy rule).
- **Click to jump** keeps the rule above by default (the clicked line lands at the pointer's height); landing on the center marker is a parameter.
- **Fixed side:** the center marker stays on the right in every language, like the window layout.

```
 content                              map
┌────────────────────────────┬─┐   ┌──────────┐
│ ...                        │ │   │ ▬▬▬▬     │
│ ...                        │ │   │ ════     │
│ ...                        │ │   │ ──────── │  ← viewport top (orange)
│ ...                        │ │   │ ▬▬▬▬▬▬   │
│ ...          ─────────────▸│ │   │ ────────▸│  ← center marker (green)
│ ...                        │ │   │ ▬▬▬▬     │
│ ...                        │ │   │ ──────── │  ← viewport bottom (orange)
└────────────────────────────┴─┘   └──────────┘
        center marker: 1/3 of the window width, right-aligned
```

#### Marker parameters (agreed)

Every marker behavior is a parameter of the scroller, under its markers settings.

| Parameter | Default | Options |
| --- | --- | --- |
| Markers | On | On, off |
| Viewport marker color | Orange (theme role) | Any theme color |
| Viewport line width | 1 px | 1–3 px |
| Viewport band tint | On, very faint | Off, opacity |
| Center marker color | Green, semi-transparent (theme role) | Any theme color, opacity |
| Center marker width | 1 px | 1–3 px |
| Center marker length in content | 1/3 of the window width | Fraction of the width |
| Center marker alignment | Right | Right, left, centered |
| Center marker in the map | Full map width | Full, same fraction as content |
| Center marker visibility | While scrolling and while the map is open (suggestion) | Always, while scrolling, off |
| Fade-out after scrolling stops | About 1 s (suggestion) | Time |
| Pixel unit | Logical pixel (suggestion) | Logical, physical |
| Jump anchor | Pointer height | Pointer height, center marker |

### Landmarks on the map (agreed)

Nobody creates landmarks by hand. They come on their own:

- **Search hits,** as soon as the user searches.
- **Footprints:** the places the user actually read, from the regions recorded in episodes. (research) A footprints scrollbar made returning to previously visited places much faster (Alexander et al. 2009).
- **Structure:** headings, images and tables, which framework widgets already know.
- (suggestion) Footprints follow the privacy rules: they come from the same encrypted history, stop when learning is paused, and are never shown for blacklisted apps.

### Horizontal scrolling (agreed)

- **In text,** Ctrl+←/→ moves the cursor by words.
- **Images and wide content** scroll sideways.
- **Very long lines** use the horizontal scrollbar, with the same map and magnifier as the vertical one.
- **The wheel scrolls horizontally when the pointer is over the horizontal scrollbar.** A touchpad or tilting wheel scrolls sideways directly.

### Back after a jump (agreed)

- Any jump (map click, Ctrl+Home/End, a search result) leaves the previous position as a marker, with a key to return.
- (suggestion) The key itself, and how many positions are kept.

### Scroll direction (suggestion)

- Configured by the compositor for every input device, so one setting applies to every app.
- **Touchpad: natural scrolling** by default (content follows the fingers).
- **Mouse wheel: traditional** by default, with a setting. Users arrive with years of wheel habit.
- The first-run setup may ask once, with a short preview of each direction.

### Experiments, later

- **Zoom out while scrolling fast** (speed-dependent automatic zooming, Igarashi and Hinckley 2000). Zooming out roughly doubles the comfortable speed. Needs careful tuning and must follow the epilepsy rules.
- **Precision by moving sideways** while dragging the thumb: further from the scrollbar, finer movement (OrthoZoom, Appert and Fekete 2006).

## Text field and text area

This section covers what is specific to Kuroko. Ordinary properties (font, text color, border style and so on) are parameters as in any toolkit and are not listed.

### States (agreed)

| State | Focusable | Selectable / copyable | Editable |
| --- | --- | --- | --- |
| Read/write | Yes | Yes | Yes |
| Read-only | Yes | Yes | No |
| Disabled | No | No | No |

- Each state has default border properties.
- States differ by shape, not only by color: for example a full hairline for read/write, no border or only a bottom line for read-only, a dimmed line plus a "not available" cue for disabled.

### Size (agreed)

Units:

| Unit | Meaning | Values |
| --- | --- | --- |
| `px` | Logical pixel, so sizes stay correct on HiDPI screens | Whole numbers |
| `lt` | One letter: the average letter width of the field's font, measured once per font and size. Exact in a monospaced font. | Whole numbers |
| `%` | Of the parent container's width | Fractions allowed |
| `ln` | One line, for a text area's height; the same line unit as scrolling | Whole numbers |

Parameters, for width (and for a text area's height):

- **`length`**: the size the field wants.
- **`min`**: a floor.
- **`max`**: optional; needed mainly when `length` is in `%`.

Resolution: start from `length`, limit by `max`, then raise to `min`. **`min` always wins,** so no combination is an error and the library never rejects one.

Examples:
- `min: 200px, length: 10lt`: ten letters wide, never less than 200 px.
- `length: 50%, max: 75lt`: half the space, never wider than a comfortable reading line (Human Factors: 50–75 characters).

### Overflow in a single-line field (agreed)

A fixed policy:

1. **Ellipsis at the end** (the logical end, so on the left in a Hebrew line).
2. **Ellipsis in the middle,** keeping start and end; for file paths (`/home/feral/…/report.odt`).
3. **Fade-out** at the edge.
4. **Marquee:** the text scrolls slowly sideways.
5. **Tooltip** with the full text on hover; can be combined with any of the above.

Marquee rules:
- **Runs on hover or focus** by default; "always" is a parameter. Moving text that starts on its own must be stoppable (WCAG 2.2.2), and constant motion pulls attention.
- **Pauses at each end** (about 1 s) so the start and end can be read.
- **Slow by design:** "scroll back" is back-and-forth motion, covered by the epilepsy rules. "Jump to start" is a quick fade, never a flash.
- **Speed in `lt` per second,** so it stays readable at any font size.
- **Direction follows the text:** a Hebrew line scrolls the other way.
- **Stops when the field is focused for editing;** normal caret-following scrolling takes over.

| Parameter | Default | Options |
| --- | --- | --- |
| Overflow | Ellipsis at the end | End ellipsis, middle ellipsis, fade, marquee |
| Tooltip with full text | On | On, off |
| Marquee trigger | Hover or focus | Hover or focus, always |
| Marquee speed | (to tune) | `lt` per second |
| Pause at ends | About 1 s | Time |
| End behavior | Jump to start | Stop at end, jump to start, scroll back |
| Cycles | (to tune) | Count, unlimited |

### Fill helper (agreed)

A suggestion list aligned to the cursor. It appears at the end of the text, or when the user selects a word or part of one, and suggests the next word or completes the current one.

- **Size:** 4 suggestions by default, up to 7 as a parameter (about 4 are recognized at a glance). Shown as a list or a grid.
- **Placement:** below the current line, aligned to the start of the word; above it when there's no room below. It never covers the line being typed. Its alignment follows the word's direction.
- **Stable while aiming:** the list updates as the user types, but never while the pointer moves toward it.
- **Keys:** when the helper is showing, **Tab accepts** the highlighted suggestion and arrows move within it. Escape closes the helper; after that, Tab moves focus as usual. A click accepts any suggestion.
- **A selection is replaced** by the accepted suggestion.
- **Never in password fields.**

Sources, set through the controller, from a fixed set:

| Source | Behavior |
| --- | --- |
| Dictionary | One or more built-in dictionaries; the language is chosen by the script of the current word |
| Static list | The app passes a list once |
| Object list | The app passes records, with a **display field** (shown), an **insert field** (typed in; may differ, for example an ID or an email) and an optional **detail field** (a second, dimmer line) |
| App-provided | The library asks the app for suggestions for a prefix; the app answers asynchronously |

- **The library makes no network calls.** A remote source is "app-provided": the app fetches from wherever it wants and answers. In Kuroko's own apps, only the gateway reaches the network.
- **Timing:** local suggestions appear within 0.1 s. Remote ones are **added** when they arrive and never reorder words already shown. Typing cancels stale requests, with a short debounce.
- **Matching policy:** prefix, contains, fuzzy.

### Alignment and direction (agreed)

The standard behavior: **base direction and alignment come from the first strong character** (Unicode bidi, UAX #9), the same rule as the compositor's menus.

- **Only strong characters count:** Hebrew and Arabic letters on one side, Latin and other left-to-right letters on the other. Numbers, punctuation, spaces and emoji are neutral.
- **Per paragraph:** in a text area each paragraph takes its own direction.
- **No strong characters** (empty, or only numbers): the active keyboard layout while the field is focused, so the caret moves to the right when the user switches to Hebrew; the UI language otherwise.
- **Fixed alignment** (parameter): left, right, center, and justify for a text area. Direction still follows the content, so punctuation stays on the correct side.
- **Left and right are absolute,** as the window layout never mirrors.

**Direction utility.** The library exposes a pure function that estimates a text's direction:

```
text_direction(text, method) → ltr | rtl | neutral
  method: first_strong   the first strong character decides
          by_amount      the script with more strong characters decides; a tie falls back to first_strong
```

Apps use it when they want to decide by content themselves, for example to set a fixed alignment for a read-only field. Automatic alignment "by amount" is not offered as a widget mode: in an editable field the count changes with every letter and the line would jump while the user types.

## Search field

A text field that searches or filters one or more target widgets: a list, a table, a tree or a text view.

### Display modes (agreed)

The mode is a parameter of the link between the search field and each target, so one field can drive several targets.

| Mode | Hits | Non-hits |
| --- | --- | --- |
| **Mark** (default) | Marked | Unchanged |
| **Filter** | Shown | Hidden |
| **Dim** | Unchanged | Faded, like the switcher's ghosts |

- **Mark** uses a shape as well as a tint (for example a background box plus an underline), never color alone.
- **Dim is not disabled.** Dimmed items stay clickable and keep their normal shape; disabled items also carry the "not available" cue, so the two never look alike.

### Reverse (agreed)

- **Reverses the hits** in any mode. With filter it hides what matches ("every log line except those containing `debug`"); with mark it marks everything except the matches; with dim it fades the matches.
- **A visible cue in the field** while reverse is on (for example a "≠" chip at the start), so the results never look wrong.
- **Typing a leading `!`** switches reverse on (parameter, since `!` may be a real search character in some apps).

### Unit of a hit (agreed)

- In a list, table or tree, a hit is a row or node.
- In text: **mark** marks the matching words; **filter** and **dim** work on a unit, line or paragraph. Filter by line is grep.

### Behavior (agreed)

- **Hit count** in the field ("3 of 17"); Enter and Shift+Enter move to the next and previous hit.
- **Hits appear on the document map** as landmarks.
- **Matching** uses the same policy as the fill helper (prefix, contains, fuzzy), with case sensitivity as a parameter, and matches typed keys in both Hebrew and English layouts, like the switcher.
- **No jumping:** filtering animates and keeps the order of what remains, with a short debounce while typing.
- **No match:** filter mode does not leave an empty target; it shows ghosts with a short "no match" label, as in the launcher.
- **Virtual lists:** mark and dim are done by the library on the visible rows. Filter changes the row count, so for app-provided rows the app filters, through the controller.

| Parameter | Default | Options |
| --- | --- | --- |
| Display mode | Mark | Mark, filter, dim |
| Reverse | Off | On, off |
| Reverse by typing `!` | On | On, off |
| Unit (text targets) | Line | Word (mark only), line, paragraph |
| Matching | Contains | Prefix, contains, fuzzy |
| Case sensitive | Off | On, off |
| Debounce | Short (to tune) | Time |

## Date and time picker

### Limits (agreed)

- **`earliest`** and **`latest`** bound what the user can pick. "Start" and "end" are kept for selecting a range (from–to).
- **Fixed or relative:** a fixed date or date-time, or a relative value evaluated live by the library: `now`, `today`, `today + 90d`, `now − 1h`. A form left open past midnight then never allows yesterday.
- **Time limits:** time-of-day bounds (for example working hours 08:00–18:00) and a step (for example every 15 minutes).
- **Time zone:** limits are evaluated in a stated time zone, the user's by default, so "today" means the user's today.

### Disabled dates (agreed)

Sources, from a fixed set:

| Source | Example |
| --- | --- |
| List | Specific dates passed by the app |
| Rule | Weekdays (Shabbat), holidays from the temporal calendar (chagim), recurring patterns |
| App-provided | The app answers for the visible month, asynchronously (a booking system's availability) |

- **App-provided timing:** the month appears at once; disabled marks are added when the answer arrives. Until then a date can't be confirmed.
- **Reason:** each disabled date may carry a reason ("fully booked", "holiday"), shown as a tooltip.
- **Look, selectable** per source or per reason, so a holiday and a booked date can look different:

| Disabled look | Description |
| --- | --- |
| Dimmed (default) | Faded, with the standard "not available" cue |
| X mark | An X over the number |
| Slash | A diagonal line through the number |
| Icon | An icon over or beside the number (for example a holiday icon) |

  Every option works without color; a color-only style (for example red text) is not offered.

### Behavior (agreed)

- **Navigation stops at the limits:** "previous month" is disabled when `earliest` is in the current month; months entirely outside the limits are skipped.
- **Keyboard:** arrows can land on a disabled date, so its reason can be read; Enter does nothing there.
- **Typed dates** outside the limits or on a disabled date put the field in its error state with a short message. They are never silently corrected.
- **Ranges:** a parameter decides whether a selected range may contain disabled dates (a hotel stay may not; a report period may).

## Keyboard navigation

### Home and End (agreed)

| Keys | Action |
| --- | --- |
| Home / End | Start / end of the line |
| Ctrl+Home / Ctrl+End | Start / end of the document |
| Shift + any of the above | Same, extending the selection |

- **Smart Home:** in code and indented text, the first press goes to the first non-space character, the second to the very start of the line.
- **Right-to-left text:** Home goes to the logical start of the line, which in a Hebrew line is on the right side of the screen.
- **Views without a text cursor** (lists, document viewers): Home and End go to the top and bottom.
- Development note: Mac keyboards often lack Home and End; the debug viewer maps Fn+← and Fn+→ to them.

## Scope

| Behavior | Where | Applies to |
| --- | --- | --- |
| Hover enlargement | Widget library | Framework apps (a compositor lens for other apps may come later) |
| Wheel bands, scroll direction | [compositor] input path | Every app |
| Shift = run | [compositor] input path | Every app (see Open questions) |
| Scrollbar, map, magnifier, viewport and center markers, landmarks, back marker | Widget library | Kuroko apps and third-party apps built on the framework |
| Home/End behavior | Widget library | Framework apps; other apps keep their own |
| Text field and text area: sizing, overflow, fill helper, alignment | Widget library | Framework apps |
| Search field: display modes, reverse, hit units | Widget library | Framework apps |
| Date and time picker: limits, disabled dates | Widget library | Framework apps |

Apps built with other toolkits draw their own scrollbars inside their windows, so the compositor cannot change them.

## Open questions

- [ ] Notch rates that switch between the slow, fast and very fast bands; tune by feel in the debug viewer with the timing histograms.
- [ ] Maximum pages in the map (about 5?) and where sliding starts.
- [ ] Magnifier size: how many lines, how wide.
- [ ] Shift = run in apps from other toolkits: those apps see Shift held and turn vertical wheel events into horizontal ones. The compositor would have to hide Shift from that app while scrolling. Is that acceptable, or does Shift = run apply only to framework apps?
- [ ] Exact color values for light and dark themes: accent, viewport marker (orange) and center marker (green, opacity).
- [ ] Center marker visibility default and fade-out time; confirm in the debug viewer.
- [ ] Scroll direction defaults and whether first-run setup asks.
- [ ] The key for "back after a jump".
- [ ] Fill helper learning from the user's own typing: none, only from dictionaries the user adds to, or learned words (not sentences) under the history's encryption and "pause learning" rules. The design concept says typed text is never stored.
- [ ] Marquee default speed and number of cycles; tune in the debug viewer.
- [ ] Date picker: show the Hebrew calendar date beside the Gregorian one (always, by locale, or a parameter)?
- [ ] Date picker: first day of the week by locale (Sunday in Israel), or a user setting?

## References

- Hinckley, K., Cutrell, E., Bathiche, S., Muss, T. (2002). Quantitative analysis of scrolling techniques. CHI 2002. https://www.microsoft.com/en-us/research/publication/quantitative-analysis-of-scrolling-techniques/
- Wallace, A., Savage, J., Cockburn, A. (2004). Rapid visual flow: how fast is too fast? AUIC 2004. https://crpit.scem.westernsydney.edu.au/confpapers/CRPITV28Wallace.pdf
- Quinn, P., Cockburn, A., Casiez, G., Roussel, N., Gutwin, C. (2012). Exposing and understanding scrolling transfer functions. UIST 2012. https://doi.org/10.1145/2380116.2380161
- US Patent 6856326, Smooth scrolling system and method. https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/6856326
- Igarashi, T., Hinckley, K. (2000). Speed-dependent automatic zooming for browsing large documents. UIST 2000. https://www-ui.is.s.u-tokyo.ac.jp/~takeo/papers/uist2000.pdf
- Appert, C., Fekete, J.-D. (2006). OrthoZoom scroller: 1D multi-scale navigation. CHI 2006.
- Alexander, J., Cockburn, A., Fitchett, S., Gutwin, C., Greenberg, S. (2009). Revisiting read wear: analysis, design, and evaluation of a footprints scrollbar. CHI 2009.
- Hornbæk, K., Hertzum, M. (2007). Untangling the usability of fisheye menus. ACM TOCHI 14(2).
