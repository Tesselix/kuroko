# Desktop Users — Human Factors and Problems of Current Desktops

Oct 9, 2026 · @feral keep

## Purpose and scope

This document describes how people use a desktop, what makes the experience better, and what is wrong with current desktops. It is the reference for giving feedback on the AI-aware compositor design. Solutions listed here are points that help define the new desktop, not final designs.

Notation: items marked **(agreed)** were confirmed in discussion. Items marked **(suggestion)** came up as feedback and are not yet decided. Items marked **(research)** come from published studies or standards, listed under References. Where research and the working estimates in this document differ, the research wins.

## Who the user is

- The baseline user is a healthy adult.
- Not every disability can be covered. Two groups are in scope from the start:
  - **People prone to seizures (photosensitive epilepsy).** No flashing or flicker, no rapid back-and-forth motion, no large sudden brightness changes (for example a large white window popping up over a dark screen should fade in).
    - (research) WCAG 2.3.1: nothing may flash more than **3 times in any one second**, unless the flashing area is small: no more than about 25% of a 10° field of view (roughly a 341 × 256 px block on a 1024 × 768 reference screen). Saturated red flashes are treated as more dangerous. A spinner, a pulsing badge or a blinking highlight must stay under these limits.
  - **People with color vision deficiency (color blindness).** State is never carried by color alone. Use shape, position, icons or text as well (running indicators, badges, warnings, focus).

## How users interact

- Users interact through **eyes** (reading, locating), **ears** (alerts, voice) and **hands** (keyboard, mouse, gestures). The **brain** coordinates all three, and its attention is the scarce resource.
- Two modes of effort:
  - **Low effort (habitual).** A repetitive task with a well-known, stable starting point becomes almost automatic.
  - **High effort (focused).** Most desktop work: reading needs focus, aiming the pointer at a target needs visual attention and motor precision.
- Consequence: habits only form when starting points stay put. Anything that moves turns a habitual action back into an effortful one, or into a mis-click.

## Perception of time

Users judge the desktop by a few time categories. They are about how things feel, not how long they take for the computer.

| Category | Time | What the user feels |
| --- | --- | --- |
| **Real time** | Continuous | Something is seen as happening now. About 24 frames per second is perceived as motion; quick movement can be distinguished up to about 50 fps; slow movement looks continuous even at about 10 fps. |
| **Immediate** | Up to 0.1 s | The response seems to happen the moment the user acts: a key press, a mouse click, the pointer following the mouse. |
| **Fast** | Up to 2 s | The user expected an immediate reaction, but is fine with the result arriving within 2 s (for example a window opening after a double-click). |
| **Slow** | 2–5 s | The user notices it takes long, but does nothing and waits. |
| **Stuck** | Over 5 s | The user starts wondering whether the action failed and whether to act: cancel, click again, retry. |

- If the window does eventually open after a long wait, the user marks that app as **slow**. If this repeats, the user learns to wait for it and not take action. This is still a bad state: the user has adapted to a bad experience.

### Research context

- (research) The classic limits (Miller 1968, Card et al. 1991, Nielsen 1993) match this model closely:
  - **0.1 s** is the limit for the system to feel like it is reacting instantly; no feedback is needed beyond the result. It is also the limit for the user to feel they are directly manipulating the object rather than giving the computer an order.
  - **1 s** is the limit for the user's flow of thought to stay uninterrupted. Beyond 1 s, show that the system is working (for example a busy cursor).
  - **10 s** is the limit for keeping the user's attention. Longer operations need a percent-done indicator and a clear way to interrupt; afterwards, users need to reorient themselves.
  - Animations should be timed by a real clock, not by how fast the computer runs, so a faster machine doesn't make them too fast to follow.
- (research) Google's RAIL model (2015) gives similar engineering targets: acknowledge input within 100 ms (process it within 50 ms), render each animation frame in under 16 ms (60 fps), and make content usable within 5 s, which matches the "stuck" boundary above.
- (research) **Direct manipulation is much stricter than a click.** For a pointer, a dragged window or a pen stroke, users notice lag far below 100 ms. Microsoft Research found that typical touch screens of the time lagged about 100 ms, that a test system at about 1 ms felt like moving a physical object, and that lag while inking becomes noticeable around 50 ms. So "within 0.1 s" is right for a click's response, but the pointer and anything being dragged must track the hand with the lowest latency the hardware allows, every frame.
- Frame rate in practice: the compositor should render at the display's refresh rate (60 Hz or more) without missing frames. The thresholds above describe when motion is perceived at all; smooth interactive motion needs every frame.

### Suggestions for the desktop

- (suggestion) **Acknowledge every action within 0.1 s, even if the result takes longer.** When an app is launched, the compositor immediately shows a placeholder at the window's final position and size (frame, icon, title), and the app's content fills it when ready. A slow start then feels "fast" instead of "stuck," and the user doesn't click again and launch a second copy.
- (suggestion) **Learn each app's start time** from the activity log. For an app known to be slow, show the expected time as progress, so the user knows it is normal.
- (suggestion) **Tell "slow" from "stuck."** The system-state layer can see whether the starting process is still using CPU, disk or network. Over 5 s, show "still starting" if it is working, or "not responding" with a cancel option if it is not.
- (suggestion) **Pre-warm apps known to be slow** when the prediction says they are likely to be needed (the design concept's pre-launch action).
- (suggestion) **The agent never blocks input.** The agent may take seconds to decide, but every user action still gets its 0.1 s acknowledgement. The input-to-pointer path has the highest priority in the compositor.
- (suggestion) Animation lengths of about 150–250 ms (see Motion and animation) fall within the "immediate" to "fast" range and don't make the user wait.

## Recognition and choice

How quickly a user picks from a set of familiar options depends on how many there are.

| Options shown | What the user does |
| --- | --- |
| **Up to 3** | Selects immediately, without analyzing. |
| **Up to 5** | Reacts fast; reading the set is not a burden. |
| **More than 5** | Has to look through the items and decide which one is needed. |

### Research context

- (research) **Subitizing (Kaufman et al. 1949).** People grasp how many items there are at a glance, quickly and accurately, for up to about **4** items. Within that range each extra item adds only tens of milliseconds; from about 5 items people switch to counting one by one, at roughly 250–350 ms per item, and make more errors. Larger sets can still be grasped at a glance when they form a familiar pattern (like the dots on a die). The boundary is about 4, so the working estimate above (3 immediate, 5 still easy) is close; design for **about 4**.
- (research) **Working memory holds about 4 chunks** (Cowan 2001), not the "7 ± 2" often quoted from Miller (1956). Items that are grouped count as one chunk.
- (research) **Hick–Hyman law (1952–53).** For familiar, practiced choices, decision time grows with the logarithm of the number of options, so doubling the options does not double the time. But when the user has to read through an unfamiliar list, each item must be scanned and time grows linearly; the law no longer applies.
- (research) **Expertise changes the cost (Cockburn, Gutwin, Greenberg 2007).** Their menu model combines pointing time, visual search for novices and Hick–Hyman decision time for experts, plus the transition between them. Novices search item by item; experts who know where things are just decide. That transition only happens when items keep their positions, which ties back to the habit rule above.

### Consequences

- What matters is not only how many items are shown, but whether they are **familiar, stable and grouped**. Eight favorites in fixed positions, shown as two groups of four, are cheaper than five predictions that change every time.
- (suggestion) Predictive slots (likely apps, cursor ring) hold **about 3–4 items**, so the right one is recognized at a glance.
- (suggestion) Larger sets (favorites, open windows, the tray) are shown in visual groups of up to 4, separated by space, so the eye reads a few groups instead of many items.
- (suggestion) Any list long enough to need scanning ("all apps") offers type-to-filter immediately, so the user narrows it down instead of reading it.
- (suggestion) Status indicators use no more than about 4 distinct states.

## Visual attention and multiple contents

- The eyes take most of the brain's attention. A user can concentrate on only one content at a time.
- Users can switch focus quickly between contents, but only if those windows are already open and visible.
- This is why many users use more than one screen. Since current desktops give no easy way to arrange several windows on one screen, users maximize one window per screen. In practice they switch between about two contents, even when the task needs more.

## Window sizing

### Problem

- Maximizing is usually not a need. It is simply the only one-click way to get a readable size, and the result is often far too big.
- The alternative, resizing with the mouse, is much slower than clicking maximize.
- Desktops allow sizes that are useless to the user, such as reading a long document in a 300 px-wide window.

### Direction: an "optimal size" control

A button that sets the window to a size calculated from its content:

1. **Width first.** Calculate the width the content needs, within reasonable minimum and maximum limits.
2. **Height from width.** At least 10 visible lines, 20 preferred. Users don't read 20 lines at once, but need lines before and after for fluent interaction.
3. **Margin.** Add about 10% on all sides.
4. **Aspect cap.** Narrow content with many lines may be much taller than wide, but no more than about **3× the width**. Beyond that, scroll (like a file info dialog).

### Reading ergonomics

- **Too wide is tiring.** Very wide lines force the head to sway from side to side. Small eye movements are fine; constant head movement is tedious.
- **Vertical scrolling is easy** (the mouse wheel is always at hand). **Horizontal scrolling is hard** and should be avoided.

Suggestions:
- (suggestion) Measure reading width in characters at the window's font size rather than in pixels. About 50–75 characters per line is comfortable. This stays correct across zoom levels, fonts and screens with different DPI.
- (suggestion) Reflowable content (articles, documents, chat) is fitted to the reading width. Fixed-width content (code with long lines, spreadsheets, tables, images) may grow wider, up to the screen, rather than force horizontal scrolling.
- Open: for apps with sidebars (mail client, IDE), is "the content" the reading pane alone or the pane plus sidebars?

## Window placement and multiple screens

- What happens inside a window belongs to the application. Placing and managing windows on the screens belongs to the desktop, and it is a big deal.
- With several screens, the mouse has to travel very far.
- There is no easy mouse way to move a window from one screen to another, even when the window is focused. The keyboard shortcut is a complex combination.
- After moving, the user usually has to resize the window to fit the new screen and move other windows out of the way so it doesn't hide them. One action becomes three or four.

Direction: moving a window to another screen is one quick action, with no cleanup afterwards. The window arrives at its optimal size for the target screen, and the layout there makes room for it.

Suggestions for the move itself:
- (suggestion) Flick the title bar toward the other screen to throw the window there.
- (suggestion) A small screen map in the cursor launcher when it is opened over a window.
- (suggestion) One modifier plus an arrow key for keyboard users.
- (suggestion) Focus and the pointer follow the moved window, so the user doesn't make the long trip anyway.

## Hidden and partly hidden windows

- Partly covered (cascaded) windows have almost no value. If the title and action buttons can't be clicked, the visible sliver only says "there is another window under this."
- The new desktop must move other open windows away from the focused window, while still allowing interaction with the non-active windows that share the same screen.

Every non-active window keeps a minimum set of interactions **(agreed)**:
- Recognize it: icon, title, live thumbnail.
- Activate or close it in one click.
- Accept drag-and-drop without restoring it first.
- Show status: progress, unread or notification badge, finished, error.
- Possibly peek: a larger preview on hover, or scrolling without changing focus.

## Multi-level scaling of unfocused windows

Example: a window at optimal size is moved (the quick way) to a screen that already has a window at optimal size.

1. **Everything fits.** The windows are placed side by side. One may be sized at the expense of the other. When focus switches, the extra width moves to the newly focused window.
2. **It doesn't fit.** The unfocused windows scale down until the focused window gets its optimal size. Start with dynamic scaling; fixed sizes may come later to limit movement. The user sees the focused window and can still interact with the others: their titles, action buttons and possibly content stay visible. Because they are small and next to the focused window, reaching them takes less mouse travel.
3. **Minimal form.** A small rectangle with the title and basic action buttons. It may miss the purpose; to be evaluated.
4. **Beyond that.** If the focused window is maximized, or the other windows would be too small to use realistically, they go to a tray reached quickly by a keystroke and mouse selection. Windows that did not fit on screen appear in the dock / cursor launcher, using the same shortcut as the launcher rather than a special key combination **(agreed)**.

Suggestions:
- (suggestion) Scale the content but keep the compositor-drawn title bar and buttons at full size, so they stay easy to hit.
- (suggestion) Scale rather than resize unfocused windows. Scaling is done by the compositor alone; resizing forces the app to re-lay itself out at a size it may not support.
- (suggestion) Decide what a click on a small window does: focus first, or act directly. A mix may work: title-bar buttons act at once, a click on content focuses first.
- (suggestion) When a window grows, keep the clicked point still so the eyes don't have to search.
- (suggestion) A few fixed scale levels (for example 100%, 60%, 35%) give windows a consistent look, which supports visual memory.
- (suggestion) Unfocused windows always gather in a consistent place relative to the focused one, so the hand learns where to reach.
- (suggestion) Keep about 4 or fewer unfocused windows visible next to the focused one (see Recognition and choice); more go to the tray.

## Motion and animation

- If windows move or an automatic mechanism reorganizes them, the user must see the movement or scaling as an animation. Jumping is disorienting.
- Animations must be quick, so they don't cost time.

Suggestions:
- (suggestion) About 150–250 ms, slightly longer for longer distances. Ease-out (fast start, slow finish); no bounce or overshoot.
- (suggestion) All affected windows animate together, not in sequence.
- (suggestion) Animations can be interrupted and retargeted from the current position; users never wait for them to finish.
- (suggestion) Clicks during motion go to where the target will end up, or are held briefly, to avoid mis-clicks.
- (suggestion) A "reduce motion" setting replacing movement with a very short crossfade.
- (research) Time animations by the clock, render every frame at the display's refresh rate.
- Epilepsy constraint applies: no flashing, no repeated back-and-forth, no sudden large brightness changes; at most 3 flashes per second (WCAG 2.3.1).

## The dock

### Problem

- The dock sits at the screen edge and permanently takes space from applications. Auto-hide is the only relief.
- Every use means traveling all the way to the bottom of the screen, even when the dock is on every screen.
- Its contents are mostly fixed. Scrolling through dock icons is useless, and cluttering the dock with icons lowers productivity.

### Direction

- The dock is hidden when not in use and appears quickly at the mouse: under the pointer, or above it when the pointer is at the bottom of the screen.
- While in use it is the user's main focus, so it can contain much more than a fixed list of icons.
- A layout of **likely apps (based on most-used applications) + a row of favorite applications + a quick option to show all apps** is far more productive than clicking around to find an icon.
- Windows that did not fit on screen are also reachable here **(agreed)**.

Suggestions:
- (suggestion) This merges the dock with the cursor launcher of the design document into one summoned surface.
- (suggestion) The likely-apps row holds about 3–4 items. Favorites are shown in groups of up to 4 (see Recognition and choice).
- (suggestion) Favorites keep fixed positions. Likely apps may change only between openings, never while visible. A predicted app that is already a favorite is highlighted in its slot, not shown twice.
- (suggestion) Fixed capacity per row, no scrolling. "All apps" opens with type-to-filter.
- (suggestion) Summoned by hotkey, held middle button, extra mouse button or gesture; opens toward the inside near any screen edge; closes with Escape, a click outside or moving away.
- (suggestion) The dock appears immediately (within 0.1 s) when summoned.
- (suggestion) Clicking a running app's icon focuses its existing window; a new instance needs a deliberate action. Several windows of one app may be grouped under its icon.
- (suggestion) A window chosen from the launcher opens on the screen where the pointer is.
- (suggestion) A small permanent hint (corner icon or thin edge strip) so new users can find the hidden dock.
- (suggestion) Running and notification indicators use shape or position, not only color.

## Reference: Apple iPadOS

Apple is the only vendor found actively rethinking desktop-style window management; others rely on the old window concepts. iPadOS 26 (shipped on the M5 iPad; since succeeded by iPadOS 27, not yet reviewed) is a useful reference:

| iPadOS 26 feature | Relation to this design |
| --- | --- |
| Apps open full screen; a grab handle turns them into resizable windows | Matches "maximize is the simple default"; we add a calculated optimal size |
| Tiling by flicking a window | Supports flick-to-throw between screens |
| Remembers each app's window size and position | A simple form of learned sizing preferences |
| Rendering optimized by which windows are actively used | Same as our background throttling of shelved windows |
| Menu bar hidden until swipe-down or cursor at top; includes search | Same "hidden until needed" principle as our dock, but still requires a trip to the edge |
| Exposé shows all open windows | A separate mode; our shelf and cursor launcher aim to remove that step |
| Stage Manager groups windows into stages | Manual working sets; ours are inferred and can be pinned |
| Background task progress via Live Activities | Supports status on shelved windows |
| Slide Over removed, then brought back | Evidence that a quick floating window is worth keeping |

Where this design goes further: no overlapping windows, sizes calculated from content, switching from a surface at the pointer instead of a separate mode, and prediction.

## Design checks

Questions to ask of every feature:

1. Does it reduce focused effort, or does it break a habit?
2. Does anything the user relies on move without the user's action? If it moves, is the motion animated and quick?
3. Can every visible window be identified and interacted with?
4. How far does the mouse travel? Can the target come to the pointer instead?
5. Does it avoid horizontal scrolling and over-wide lines?
6. Is any state shown by color alone?
7. Could any animation or transition flash or flicker (more than 3 times per second)?
8. Is every user action visibly acknowledged within 0.1 s?
9. Can anything wait more than 5 s without showing status and a way to cancel?
10. Does a choice show more than about 4 ungrouped or unfamiliar items at once?

## Open questions

- Should small windows be allowed to float on top (picture-in-picture video, calculator, color picker, dialogs attached to a parent), or is the no-overlap rule absolute? The return of Slide Over on iPad suggests some floating windows are valuable.
- What counts as "the content" for optimal width in apps with sidebars?
- Dynamic scaling versus fixed scale levels.
- Whether the minimal title-only form (level 3) is useful.
- Design of the tray for windows that don't fit (to be described).

## References

- Miller, R. B. (1968). Response time in man-computer conversational transactions. AFIPS Fall Joint Computer Conference.
- Card, S. K., Robertson, G. G., Mackinlay, J. D. (1991). The information visualizer: an information workspace. CHI '91.
- Myers, B. A. (1985). The importance of percent-done progress indicators for computer-human interfaces. CHI '85.
- Nielsen, J. (1993). Response Times: The 3 Important Limits. https://www.nngroup.com/articles/response-times-3-important-limits/
- Google Chrome team (2015). RAIL performance model. https://developer.mozilla.org/en-US/docs/Glossary/RAIL
- Ng, A., Dietz, P. et al., Microsoft Research (2012). High-performance touch / latency perception. https://www.microsoft.com/research/video/applied-sciences-group-high-performance-touch
- Annett, M., Ng, A., Dietz, P., Bischof, W. F., Gupta, A. (2014). How low should we go? Understanding the perception of latency while inking. Graphics Interface 2014. https://webdocs.cs.ualberta.ca/~wfb/publications/C-2014-GI-Latency.pdf
- W3C (2025). WCAG 2.2, Understanding SC 2.3.1: Three Flashes or Below Threshold. https://www.w3.org/WAI/WCAG22/Understanding/three-flashes-or-below-threshold.html
- Kaufman, E. L., Lord, M. W., Reese, T. W., Volkmann, J. (1949). The discrimination of visual number. American Journal of Psychology. Overview: https://en.wikipedia.org/wiki/Subitizing
- Cowan, N. (2001). The magical number 4 in short-term memory: A reconsideration of mental storage capacity. Behavioral and Brain Sciences 24(1). https://www.cambridge.org/core/product/44023F1147D4A1D44BDC0AD226838496
- Hick, W. E. (1952); Hyman, R. (1953). Hick–Hyman law of choice reaction time. Overview: https://en.wikipedia.org/wiki/Hick%27s_law
- Cockburn, A., Gutwin, C., Greenberg, S. (2007). A predictive model of menu performance. CHI 2007. https://doi.org/10.1145/1240624.1240723
