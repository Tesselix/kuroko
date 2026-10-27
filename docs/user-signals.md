# Tesselix — Signals for Clipboard, Sensitive Windows and Interest

Oct 27, 2026 · @feral keep

## Purpose

Three features are still being defined: a clipboard history with trusted paste, sensitive windows, and "recent" based on real interest. Their detailed design comes later. This document records the concepts and, more importantly, the **facts Tesselix must provide** so that they can be computed when they are designed. Building these facts in early is cheap; adding them to a finished compositor is not.

Notation follows the Top-Level Design: **(agreed)**, **(suggestion)**, **[compositor]**, **[desktop]**. The concepts are the user's (agreed as concepts); everything about how they work is a suggestion.

## The concepts

### Clipboard history and trusted paste (agreed, concept)

- Tesselix keeps a **history of copies**.
- The latest few (about 5) are one quick action away: the user can **swap the current clipboard content** with one of them before pasting.
- **What a copy remembers:** the app it was copied from, that app's **signature** (the digest of its binary, as in the Tessel Store's authorization check) and the **object** that was open in the source window (file, URI, folder).
- **Trust is the app and its open object together.** The same editor has one trust level with a sensitive contract open and another with a scratch note open.
- **Trust rule:** at paste, Tesselix works out the target's trust from the target app and the object open in the target window, and allows the paste only if it is the **same trust level** as the source's.
- **On a mismatch, Tesselix warns** that the trust levels do not match, and lets the user **raise the trust** of the target app or of the target document, then paste.
- **Simple, and rare.** The mechanism must not bother the user more than needed:
  - (suggestion) One small warning at the target window, drawn by the compositor, with at most three choices: **Trust this document**, **Trust this app**, **Cancel**. The first two paste right after raising the trust. Esc cancels.
  - (suggestion) A raised trust is remembered, so the same paste never warns twice.
  - (suggestion) Trust is raised only up to the source's level, never higher.
- **Details are managed in the window's Security section** (agreed): the icon menu's Security group (Top-Level Design, "Icon menu") shows the trust of the window's app and document, lets the user raise or lower it, lists the raised trusts and takes them back, and marks the app or document as sensitive. The paste warning stays minimal because the details live there.

### Sensitive windows (agreed, concept; still being defined)

- The user can mark a **URI, a file, a folder or an app** as sensitive.
- While a sensitive object is on screen, Tesselix can **hide its content quickly**: blur it when the pointer is not over it, blur it after a time without interaction (like a screen saver, without locking), or blur it or show **decoy content** at once on a quick gesture (both mouse buttons, a shortcut).
- The goal is to prevent shoulder surfing.

### Interest instead of "recent" (agreed, concept)

- Today "recent" means "opened last", so files opened by mistake and closed at once push out the ones that matter.
- An object becomes **interesting** only through **real interaction**:
  - A video: watched for more than about 20 seconds, the count restarting when the user jumps to another point.
  - A document: a pattern of actual reading.
- **Cycles:** when the user opens an object as part of a repeated pattern (every workday, in the first hour after the first login), Tesselix shows it as interesting when the pattern's time comes again (that first hour).

This is the Design Concept's episodes, salience and cycle detection, with "recent" replaced by "interesting".

## Where things are decided

Following the guiding rule (Architecture), the compositor provides facts and enforces fixed policies on its own paths; desktop services do the thinking.

| Decision | Where | Why there |
| --- | --- | --- |
| Is this paste allowed (trust levels)? | [compositor] | Clipboard data flows through the compositor; a check elsewhere could be bypassed. It uses the object trust that desktop services sent ahead of time, so the check never waits. |
| The trust level of an object (file, URI, folder) | [desktop] | The user's marks and rules; sent to the compositor per window |
| The mismatch warning and the user's choice | [compositor] | Only the compositor's own UI can be trusted to show the warning and to know the choice came from the user, not from an app |
| Storing a raised trust | [desktop] | Kept with the user's marks; the compositor's stored window trust is updated at once, so the paste goes ahead without waiting |
| Hide now (gesture, pointer left, idle) | [compositor] | Must take effect in the same frame, and must hold even if services are down |
| Which objects are sensitive | [desktop] | The user's list; sent to the compositor as a per-window flag |
| Is this video or document interesting? | [desktop] | Recorder and memory, from episodes |
| Cycles, "interesting now" | [desktop] | Memory, with the temporal calendar |

## Facts Tesselix must provide

Five facts serve all three features.

### 1. Who an app is, and its trust level

- Every Wayland client is tied to its **process** (PID and pidfd from the socket's peer credentials), its **executable**, the executable's **signature** (digest) and its **trust level** (Tessel Store, "Trust levels"). This is fixed when the client connects and re-checked when the process `exec`s.
- This is the app half of trust. The object half comes from fact 2: a window's trust is the combination of its app's trust and the trust of the object it shows.
- Every window, copy, paste and interaction event carries the client's identity.

### 2. What object a window shows

All three features ask the same question: which file, URI or folder is in this window, and when did that change?

- Sources, best first:
  - **Tesselix apps** report it over the Tesselix protocol (document URI, and changes such as a new tab).
  - **Accessibility (AT-SPI):** browsers and office apps expose the document URL or file.
  - **The process's open files** (`/proc/<pid>/fd`) for apps that keep their file open.
  - **The window title** as a last resort, with per-app patterns.
- The answer is a **window → object** mapping with a confidence and a time of change, kept by the context hub [desktop] and sent to the compositor where it needs it (the sensitive flag).
- **Unknown is a valid answer.** A sensitive app is known from fact 1 even when its object is not.

### 3. Interaction per window

The compositor sees every input and knows what is on screen. It reports, per window (suggestion: as the "input summaries" the event publisher already lists):

- **Visibility:** shown (and how much of it), covered, on the shelf, on another space; the screen locked or off.
- **Focus:** gained and lost.
- **Pointer:** entered and left the window.
- **Input by kind, not content:** key presses as kinds (letter, digit, navigation, editing, shortcut), clicks, scroll amount and direction, page keys. Never which letters (Debugging Foundations, "Privacy"; Design Concept, "Privacy and safety rules").
- **Idle:** time since the last input, for the whole session and per window.
- **Session:** login, unlock, lock, suspend and resume, with times. "The first hour after the first login of the day" is computed from these.

Reading patterns and video watching need more than the compositor sees:

- **Reading:** the scrolled position and the part of the document in view, over time. Tesselix apps report it (the document view knows it); for others, AT-SPI where possible, else scroll events from the compositor.
- **Media:** playing, paused, position and seeks, from MPRIS (D-Bus) and PipeWire streams [desktop]. "Watched more than 20 s since the last seek" is computed from these.

### 4. Clipboard events

The compositor owns the clipboard (txwl's data device, today accepted and ignored). It records:

- **Copy:** source app, its signature, the source window and the object open in it, the combined trust level, time, the offered types (MIME), size, and whether the source marked it secret (password managers use a hint type for this).
- **Paste:** target app, its signature, the target window and the object open in it, the combined trust level, time, the type asked for, and whether it was allowed.
- **The object is taken at the moment of the copy and of the paste,** since a window's object changes (a new tab, another file). If the object changed in the same instant, the earlier mapping counts.
- **The check never waits.** The compositor holds each window's current combined trust, kept up to date by desktop services as the window's object changes. At paste it compares two stored values.
- **Content** is read from the source **when the copy happens**, so history survives the source closing. It is kept in memory, or encrypted at rest like the history, never in logs or traces.
- A copy from a **sensitive** window or marked secret is itself sensitive: it can be left out of the history or shown masked.

Required capabilities:

- **The compositor can offer its own clipboard data,** acting as the source when the user swaps in an older copy.
- **No bypass:** protocols that let a client read or set the clipboard without a user action (`ext-data-control`, `wlr-data-control`) are given only to Tesselix's own processes. Primary selection and drag-and-drop follow the same trust rule.

### 5. Per-window effects in the compositor

- Each window's layer can be shown **as is, blurred, or replaced** (decoy or a solid placeholder) by the renderer, switched within one frame (part of the layer list in the GPU design).
- **Everywhere the window's pixels appear:** its tile, shelf thumbnails, the switcher, previews, flying animations, screen capture and screen sharing, and debug captures. A hidden window is hidden in all of them.
- **Fail safe:** if the compositor does not know whether a window is sensitive yet (services down or still deciding), the user's last known marks still apply, kept by the compositor.
- The gesture (both mouse buttons, a shortcut) is caught by the compositor before any app sees it.
- Hiding and showing follow the human-factors rules: a short ease (150–250 ms) when the pointer leaves, **immediate** on the gesture, and never flashing.

## Overlap with debugging

The interaction facts and the debugging trace come from the same places in the compositor and use the same IDs (Debugging Foundations, "Identity"). They are **separate outputs** with different rules:

- The trace is for developers, off by default at detail level, never written in normal use beyond the flight recorder.
- Interaction summaries go to the recorder, which folds them into episodes and keeps them encrypted.
- Clipboard content goes to neither.

## What this means for the code now

- Done (2026-10-27): every client is tied to its PID and binary at connect time; the user can mark apps, files and folders trusted or untrusted; the compositor decides each window's trust and publishes it. Details: `docs/implementation-notes.md`, "Identity and trust". Still to do here: the pidfd (a PID can be reused), and re-checking the binary when the process `exec`s.
- txwl: a real data device (copy and paste), with the compositor able to be the source, and every copy and paste recorded with source and target.
- The layer list: a per-layer "content mode" (as is, blurred, replaced) and one switch that covers every place a window's pixels are drawn.
- The event publisher: per-window interaction summaries (visibility, focus, pointer, input kinds, idle) and session events, next to the scene-graph deltas.
- The Tesselix protocol: Tesselix apps report the object they show and the part in view.

## Open questions

- [ ] Sensitive windows: the hide triggers, the gesture, decoy content, how long before idle hiding.
- [ ] Clipboard: history length, how the swap is shown and chosen.
- [ ] Trust: the levels for objects, and how an app's level and an object's level combine (the lower of the two, a table, or a pair compared as is).
- [ ] Trust: the level of a window whose object is unknown (lowest, or the app's level alone).
- [ ] Trust: on a mismatch, is the paste held until the user chooses, or does it go ahead with the warning shown alongside?
- [ ] Trust: is a raised app trust tied to the app's signature (lost when the app updates) or to the app itself? Now: to its binary's path; the signature is recorded but not checked. A copy of an installed app at another path has the same signature but is not trusted.
- [ ] Trust: how installed apps earn trust (now: any installed app is trusted).
- [ ] Trust: also offer "Paste once" without raising anything, or keep the warning to raising trust only?
- [ ] Clipboard: are secret and sensitive copies left out of the history, or kept masked?
- [ ] Interest: what counts as "a pattern of reading" per kind of object.
- [ ] Interest: how a cycle is announced (launcher entry, a marker in "Relevant now").
- [ ] Window → object mapping for apps that show several objects at once (tabs, split views).
