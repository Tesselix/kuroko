# AI-Aware Compositor — Design Concept

Oct 6, 2026 · @feral keep

## Vision and core principles

The compositor is itself a local, ambient assistant: it watches how the user works and quietly prepares the desktop for what they are most likely to do next.

- **The compositor is the agent.** A small model runs locally inside it and handles window work. Harder questions escalate to a large remote model through an API key.
- **Prepare, don't move.** Predictions make the likely action easier (pre-warm, rank, suggest). Nothing the user is looking at rearranges itself uninvited.
- **Explicit beats implicit.** A direct user command always overrides a prediction.
- **Text, not pixels.** The agent reasons over compact, structured text descriptions of the screen, the system and past activity, not over images.
- **Local-first and private.** Raw activity never leaves the machine. The learned profile is inspectable and can be wiped.
- **Reversible is automatic, destructive is proposed.** Throttling or freezing can happen on its own; deleting, killing or uninstalling is only ever suggested.

## Agent architecture

A small local model decides; deterministic compositor code executes; a large remote model is consulted only for questions beyond the small one.

- **Out of the render loop.** The agent runs async in its own thread or process and is triggered by events, never per frame. Seconds of latency are acceptable.
- **Structured actions, not text.** The local model emits commands from a fixed vocabulary (move, resize, shelve, pre-launch, rank, suggest). This keeps it safe, testable and cheap.
- **Narrow local job.** Layout, focus, grouping and "which window does the user mean" fit a 0.5 to 3B quantized model on CPU (for example via llama.cpp). Open-ended reasoning does not.
- **Escalation is the security boundary.** The local model writes a summary of the situation for the remote model. Raw activity, screen pixels or file contents cross only with explicit user approval.
- **No GPU assumed.** Every always-on component must run acceptably on a CPU-only machine.

Data flow:

```
Scene graph | System state | Temporal context | Episode log
                        │
                        ▼
 Retrieval + classical predictors (salience, cycles, working sets)
                        │
                        ▼
        Small local model (CPU, event-driven, async) ──summary──▶ Remote large model (API key, on demand only)
                        │
                 structured actions
          ┌─────────────┼──────────────┐
          ▼             ▼              ▼
 Launcher, dock,   Attention      Sysadmin
 cursor ring       tiling         proposals
```

Only a summary ever crosses to the remote model; everything above the local model stays on the machine.

## Context layers

Three always-current text layers give the agent what is on screen, what the machine is doing and where we are in time.

### Semantic scene graph

A structured description of the whole screen, updated on events (draw, move, resize, widget change), never computed from pixels.

- Hierarchy: output → workspace → window → regions → widgets. Each node has a stable ID, type, geometry, state and a few typed attributes.
- Fixed schema of enums and numbers, not free text. Internally binary (protobuf or CBOR); rendered as terse text for the model. Target: a full desktop in a few hundred tokens.
- Updates arrive as deltas, so the model never re-reads the whole tree.

The compositor sees only surfaces and buffers, not widgets, so the tree is assembled from four sources:

| Source | Gives | Cost |
| --- | --- | --- |
| Compositor-native | Outputs, workspaces, windows, subsurfaces, popups, app ID, title, geometry, focus | Free, exact |
| Accessibility tree (AT-SPI over D-Bus) | Widget roles, names, bounds for GTK, Qt, browsers, LibreOffice, Electron | Low |
| Own apps (e.g. gtty) via a custom protocol | Richest structure, published by the app | Low |
| Vision fallback | Layout of apps with no accessibility (games, canvas apps) | High; run once on layout change, cached as text |

### System state

The same compact style for the machine itself, joined to the scene graph by PID and cgroup so the agent knows which window is heavy.

- Load: CPU, memory, swap and pressure stall info (PSI) from /proc and cgroups.
- Network: link state (NetworkManager), active connections (netlink), per-process throughput where possible.
- Power and hardware: battery and AC (UPower), thermals, displays, devices.
- Session: idle time, lock and unlock, notifications.
- Sampled internally, emitted only on meaningful threshold changes.

### Temporal context

Time of day, weekday, position in the week, month and year, plus a calendar of holidays and personal events (including the Hebrew calendar: Shabbat and chagim). Used as features by every prediction.

## Activity recording

Raw input is captured briefly, folded into compact episodes at meaningful boundaries, and then discarded.

- **Raw buffer.** Every key, click and window event in an in-memory ring buffer covering minutes. Never written to disk.
- **Episodes.** On a boundary (save, close, focus switch, long idle) the buffer collapses into one record and is cleared.
- **What an episode keeps:** time to first interaction, dwell versus active time, typing speed and bursts, correction rate, navigation (arrows, page keys, clicks), the regions of a document actually viewed, and key actions (save, load, send).
- **What it does not keep:** the typed text itself. On save it stores a pointer to the file plus a diff hash or short summary; content is fetched only when the agent needs it.
- Window geometry is recorded only when it changes, not continuously.

Example episode (a few hundred bytes):

```
ep doc-edit win=42 app=libreoffice file=@f17
open=09:12:03 first_input=+41s dwell=23m active=17m
typing: chars=1840 wpm=52 bursts=14 corrections=8%
nav: arrows=63 pgdn=9 clicks=22 scroll_regions=[0-35%,60-80%]
actions: [save@+12m, save@+23m]
content: diff_ref=@d203 summary="added section 3"
```

## Long-term memory

Three mechanisms on top of the episode log decide what matters to the user, what can be forgotten and what belongs together.

1. **Salience with decay.** Every resource (document, repo, host, URL, app) gets an importance score from frequency, dwell and active editing. Without new activity the score decays, and old episodes compact further or are pruned (for example after a year).
2. **Cycle detection.** Before anything is forgotten, check whether its activity is periodic (weekly, monthly, bimonthly VAT report, yearly tax filing). A periodic resource becomes a recurring task: its score drops between cycles and rises as the next one approaches.
3. **Working sets.** Resources used together in the same time window are linked into a co-occurrence graph of the user's contexts, such as tax report ↔ receipts ↔ bank site ↔ accountant's email, or editor ↔ SSH session ↔ repo in the browser. When one member appears, the rest are the prediction.

The user's most important apps and resources are simply the heaviest nodes in this graph, weighted by salience and recency. Users can also name and pin a working set ("my tax context"), which makes predictions more reliable than inference alone.

## Personalization without a GPU

Most personalization lives outside the model's weights: facts about the user come from retrieval, habits from small classical predictors, and fine-tuning is a late, optional step.

| Layer | What it learns | How | Runs on |
| --- | --- | --- | --- |
| Retrieval (RAG) | Facts about the user and current situation | Structured queries and graph lookups over the scene graph, episodes and working sets; embeddings only for fuzzy matching | CPU, instant updates |
| Classical predictors | Habits: next app, likely file, cycles | Markov chains over transitions, frequency tables per time slot, small gradient-boosted trees | CPU, trains in seconds, continuous |
| Fine-tuning (LoRA) | The user's style of reasoning, if the model keeps misreading it | Small adapter on a 0.5 to 1B model, overnight on CPU or on another machine with a GPU | Optional, phase 3 |

Rule of thumb: the predictors do most of the predicting; the LLM interprets their output and decides what to do with it.

## User-facing features

One ranking engine ("relevant to this user right now") drives every surface that lists things, instead of sorting by date or name.

- **Launcher.** All installed apps, with a "likely" section on top: larger icons for high confidence. Context comes from what is on screen (a URL being read, a file selected).
- **Adaptive dock.** A pinned zone that never moves, plus a few predictive slots that follow the current context. Slots change only at calm moments, never while the cursor is heading toward the dock.
- **Cursor launcher.** A hotkey, click-and-hold or gesture opens a small ring at the pointer with the top predictions and a mic button. The top slot keeps a fixed position so a flick becomes habit. "Everything else" is one click away.
- **File manager search by memory.** Natural language or voice: "the document I worked on yesterday" (queries the episode log), "the video about X" (queries a local content index of document text and transcripts), or both combined. Local speech-to-text handles voice.
- **"Relevant now" quick links** (now named **Focus**, shown before Recent; see `docs/user-signals.md`). Lists, before "recent files", what the user actually engaged with, matched to the time context (start of the workday surfaces the morning working set).
- **Open-with prediction.** Once a file is selected, the app the user is most likely to open it with in this context is highlighted.
- **Email triage.** The inbox ranks by personal interest: history with the sender, open and reply rates, dwell, and what the user always ignores. Headers only; bodies are never read. Needs a mail connector or client plugin, since the compositor only sees the visible list.

UI rule: show a "Suggested" strip above the normal list rather than reshuffling the whole list, so spatial memory keeps working.

## Window layout: content-aware attention tiling

No window ever hides another: active windows share the screen sized by their content, and everything else sits on a shelf of small live thumbnails.

1. **Split by attention.** Recency and salience divide windows into an active set (usually one to three) and a background set.
2. **Size by content, not by window.** The scene graph knows each window's content region (a document page, an article column). Minimum useful width = content width plus a margin (for example 400 px content → about 480 px). A window whose content fills it keeps roughly its size. Exact margins are to be tuned later.
3. **Fill the width.** Leftover width is distributed by importance so the active set spans the screen. Height is usually full, since content scrolls vertically.
4. **Shelf.** Background windows become scaled-down live thumbnails with app icon and title, placed below the active area, one click to restore.
5. **Fallbacks.** Apps that expose no content bounds use a learned per-app preference or a sane default.

Stability rules:

- Layout changes only in response to user actions (focus, open, close), never spontaneously.
- Hysteresis: a briefly idle window does not drop to the shelf; it needs a clear threshold.
- Manual resizes are learned as preferences for that app or context, not overridden.

## Agent as sysadmin

The agent does what a professional user would do to keep the machine healthy, using salience to know what is safe to touch.

- **Salience-aware cleanup.** Candidates ranked by size × (1 − salience) × age: a large download used once goes first; small, often-referenced files are never touched. Trash is emptied in the same order.
- **Growth forecasting.** Track disk usage over time and warn early, with a list of safe candidates.
- **Background throttling.** Shelved or hidden windows get fewer frame callbacks (lower refresh rate). Under memory pressure, background apps are frozen via the cgroup freezer and thawed on click.
- **Runaway processes.** Detect a window or tab whose memory keeps growing and suggest a reload.
- **Developer clutter.** Docker images and volumes, Go, npm and pip caches, build directories in projects whose salience has decayed.
- **System cruft.** Old kernels, orphaned packages, journal size, duplicate files.
- **Health.** SMART disk warnings, battery wear, thermal throttling, crash-looping services.
- **Updates and backups.** Schedule updates when the cycle model says the user is away; verify backups run; snapshot before any cleanup.
- **Security awareness.** Unexpected listening ports, unusual outbound connections per process, failed logins, expiring SSH keys and certificates.

## Privacy and safety rules

The system is technically a keylogger and screen observer, so these rules are fixed from day one.

- Never record in password fields (AT-SPI password role), lock screens, password managers or user-blacklisted apps.
- Raw input stays in memory only; episodes and the profile are encrypted at rest with retention limits.
- Nothing leaves the machine except an approved, summarized escalation to the remote model.
- The learned profile is inspectable and can be wiped by the user at any time.
- Destructive actions (delete, uninstall, kill) are always proposed, never executed, and go through trash or a snapshot.
- Predictions never move what the user is looking at.

## Prior art and differentiation

Several projects cover one piece each; none found combines a compositor-owned semantic scene graph, compacted activity memory and passive prediction that reshapes the desktop.

| Project | What it is | Overlap | What it lacks vs. this design |
| --- | --- | --- | --- |
| [SynapseOS / synui](https://github.com/velle999/SYNAPSE) | Arch-based OS; wlroots compositor wired to a local LLM daemon (llama.cpp) over a Unix socket | Closest match: compositor that knows the AI exists, an "AI" layout, local-only model, security-aware borders | AI acts on request (layout, chat, shell); no documented activity memory, salience, cycles or predictive surfaces |
| [Botnik](https://github.com/astex/botnik) | Qt6 Wayland compositor that is a chat prompt; local LLM controls windows via tools | Compositor as agent | Command-driven, not ambient; v0.1 |
| [generational-infrastructure/distro](https://github.com/generational-infrastructure/distro) | NixOS: niri + chat panel + local LLM | Local agent on the desktop | Agent sits beside the compositor; no observation layer |
| [screenpipe](https://github.com/screenpipe/screenpipe) | 24/7 local screen + audio capture, OCR, searchable memory via MCP | Activity memory, local-first, memory search | Pixels and OCR rather than structured text; no window management or prediction |
| [Microsoft Recall](https://pureinfotech.com/what-is-recall-windows-11-ai-timeline-explained) | Windows screenshot timeline with natural-language search | "Search what I saw yesterday" | Snapshots every few seconds; proprietary; storage-heavy; heavy privacy backlash |
| [Pelorus](https://github.com/linuxserver/pelorus), [Aulinx](https://pypi.org/project/aulinx/) | LLM agents that drive a Linux desktop via the AT-SPI tree, vision as fallback | Text-based desktop state from accessibility, vision fallback | External agents that act on commands; no memory, no compositor role |

Where this design is new:

- **Text-first scene graph owned by the compositor**, updated on events, versus screenshots (Recall, screenpipe) or on-demand AT-SPI dumps (Pelorus).
- **Compacted behavioral episodes** (dwell, typing rhythm, viewed regions) instead of stored pixels or text, so far less sensitive data exists at all.
- **Ambient, prediction-first help** ("prepare, don't move") rather than a chat box that waits for commands.
- **Content-aware attention tiling** using the scene graph's content bounds; no project found sizes windows by their content.
- **Calendar-aware cycles** (including the Hebrew calendar) driving salience and recurring tasks.
- **CPU-only by design**, with personalization through retrieval and classical predictors.

Starting-point options: build on wlroots (as synui did) or Smithay; study synui's AI socket protocol and screenpipe's capture pipeline for lessons; reuse AT-SPI techniques from Pelorus for the widget layer.

Sources (opened 6 Oct 2026): [SynapseOS README](https://github.com/velle999/SYNAPSE), [synui roadmap](https://github.com/velle999/SYNAPSE/blob/main/synui/ROADMAP.md), [Botnik](https://github.com/astex/botnik), [distro](https://github.com/generational-infrastructure/distro), [screenpipe](https://github.com/screenpipe/screenpipe), [Recall explainer](https://pureinfotech.com/what-is-recall-windows-11-ai-timeline-explained), [Pelorus](https://github.com/linuxserver/pelorus), [Aulinx](https://pypi.org/project/aulinx/).

## Open questions and next steps

- [ ] Foundation: wlroots (C, drivable from Zig), Smithay (Rust), or extend an existing compositor first as a prototype?
- [ ] Formal schema for the scene graph, system state and episodes (enums, fields, text rendering).
- [ ] How shelved windows are identified at a glance (thumbnail, icon, title, or a mix).
- [ ] Trigger model: which events wake the agent, and its latency budget per surface.
- [ ] Exact escalation policy: what the summary sent to the remote model contains and how approval works.
- [ ] Retention periods and compaction schedule for episodes.
- [ ] Mail integration path: IMAP connector, local mail store, or client plugin.
- [ ] Margins and thresholds for attention tiling and hysteresis.
- [ ] First prototype slice: scene graph + episode log + ranked launcher is the smallest end-to-end loop.
