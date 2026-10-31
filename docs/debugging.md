# Kuroko — Debugging Foundations

Oct 27, 2026 · @feral keep

## Purpose

A window system is hard to debug. Many processes act at once, every frame has a deadline, and most problems are about *when* and *why* things happened, not about one bad value. Printing text cannot show that, and a debugger that stops the compositor is not an option.

This document defines what the system records and guarantees so that an advanced graphical debugger can be built on it: an inspector, timelines, a protocol trace, record and replay. It does not define how the debugger organizes or shows the stream of messages. That is a separate design. The rules here only make sure that every message carries what any organization needs: who, what, when, why, and in which frame.

Notation follows the Top-Level Design: **(agreed)**, **(suggestion)**, **[compositor]**, **[desktop]**.

## Principles (suggestion)

1. **Observing never disturbs.** Recording costs a fixed, small amount on the hot path: no allocation, no system call, no lock, no waiting. If the reader falls behind, events are dropped and the drop is itself recorded. The compositor never waits on a debugger (Architecture, guiding rule).
2. **One stream, one format.** Everything observable is a trace event, and every trace event is a Kuroko record. Live streams and recorded files are the same records, so a viewer cannot tell them apart.
3. **Everything has an identity.** Every object an event mentions has a stable ID that is never reused. Names and properties are sent once, when they change, not repeated in every event.
4. **Every effect points to its cause.** Events carry the ID of what caused them, so a chain can be followed: a key press, the focus change it caused, the configure sent to the app, the app's commit, the frame that showed it.
5. **The frame is the unit of time.** Every event in the compositor belongs to a numbered frame, and each frame records what changed, what was drawn and how long each stage took.
6. **State can be rebuilt at any point.** Snapshots plus deltas, as the event publisher already does, so a viewer can join late, seek, and show the state at any moment.
7. **The core can be replayed.** The pure-Zig core is a function of its inputs and the clock. Recording the inputs is enough to run the same session again, offline, in the simulator, and stop anywhere.
8. **What is on screen can be pointed at.** Every pixel on screen can be traced back to the layer, window and app that drew it.

## Trace events

### The record (suggestion)

A trace event is a Kuroko record (`krkcore.format`) with a fixed-width payload header, followed by kind-specific fields:

| Field | Size | What it is |
| --- | --- | --- |
| time | 8 | Monotonic nanoseconds, system-wide clock (Linux `CLOCK_MONOTONIC`), the same in every process, so streams from different processes merge by time. Not "since start". |
| seq | 8 | Per-source sequence number. A gap means events were dropped. |
| source | 4 | Which process and component wrote it (compositor input path, renderer, krkwl, krkdesk, an app, ...). |
| category | 2 | Bit or small number, for filtering at the source (see Levels). |
| kind | 2 | The event type inside the category. |
| frame | 8 | The compositor frame this event belongs to (0 outside the compositor). |
| subject | 8 | The main object the event is about (an ID, see Identity). |
| cause | 8 | The ID of the event or span that caused this one, or 0. |
| span | 8 | When the event opens or closes a span (begin/end), the span's ID. |

Kind-specific fields follow, fixed-width. Variable data (a title, a protocol message's arguments) comes as trailing bytes with a length, as in `SceneWindow`.

- Trace types get their own range in `sdk/krkcore/src/types.zig` (suggestion: `0x07xx`; `0x06xx` holds the trust marks).
- Text that already has an ID is not repeated: a window's title is sent once in a "named" event, and later events carry only the window's ID.

### Spans

An operation that takes time (a frame, a layout pass, an animation, an app's configure-to-commit round trip) is a **span**: a begin event and an end event with the same span ID. Events inside it carry the span as their cause. Spans nest. This is what lets a viewer draw timelines, and it is how a slow frame is explained: which span inside it took the time.

### Causes

The cause field links events into chains across components and processes:

- An input event gets an ID when it enters the compositor. Everything it triggers (focus, hit test, layout, a message to an app) carries that ID or a span under it.
- Messages that cross a process boundary carry the cause along: the compositor's configure to an app has an ID, and krkwl records the app's matching commit with that ID as cause. For apps that use Kuroko's widget library, the Kuroko protocol carries the cause explicitly; for other Wayland apps, krkwl infers it from the protocol (configure serial and `ack_configure`).
- A frame lists the commits and changes it shows, so "this key press became visible in frame N, 31 ms later" is a query, not a guess.

## Identity

- **Handles everywhere.** Compositor objects are already `krkcore.Handle` (index plus generation, usable as a 64-bit ID, never reused while the generation differs). Every object that events mention gets one: outputs, windows, Wayland clients, surfaces, buffers, layers, input devices, animations, desktop-service connections.
- **IDs are unique across sources.** The source is part of the identity, so an ID from krkdesk and one from the compositor cannot collide.
- **Lifecycle events.** Each object has created, named (and renamed), properties changed and destroyed events. A viewer can then show any object's whole life, and a dangling ID is visible as an event that mentions an object after its destroy.
- **Apps are tied to processes.** A Wayland client is recorded with its process ID and executable (from the socket's peer credentials), so a window links to its process, and later to its CPU and memory use.

## Frames

Every compositor frame records (suggestion):

- frame number, the time it started, the time it was presented, and the target refresh
- the stages as spans: input, layout, animation tick, render (per layer), upload or import, submit, present
- the damage: which screen regions changed and why (which layer)
- the layer list as a delta: layers added, removed, moved, resized, re-ordered, their opacity and clip
- which client commits were shown in it, and which were still waiting
- whether the frame missed its deadline, and by how much

The existing histograms (`krkcore.metrics`) stay as cheap summaries. Frame records are what explain a single bad frame.

## Layers

The layer list (the renderer's input, see the GPU design) is the debugger's view of the screen:

- Every layer has an ID, a name (`window 12 content`, `top bar`, `launcher`), its owner (window, app, compositor UI) and its rectangle, scale, clip and opacity.
- **Hit testing by ID.** The compositor can answer "what is at (x, y)?" with the stack of layer IDs at that point, top first. This makes click-to-inspect possible.
- **Pixels by reference.** Layer pixels never go into the event stream. On request the compositor copies a layer (or the whole frame) to a separate capture store, and the event carries a reference to that capture. Capturing is rate-limited and off by default.

## Levels and categories

Tracing is always on, at a level cheap enough to ship.

| Level | Contents | Default |
| --- | --- | --- |
| Always | Lifecycle (objects created and destroyed), frame summaries, missed deadlines, errors and repairs, drops, app connects and disconnects | On, in every build |
| Detail | Full frame records with stages and damage, input events (see Privacy), layout decisions, animations, Kuroko protocol messages | Off; turned on at run time |
| Protocol | Every Wayland request and event per client, with arguments | Off; per client |
| Capture | Layer and frame pixels | Off; on request |

- Categories are switched on and off **at the source**, at run time, by a control message over the Kuroko protocol. What is off costs one branch.
- A debugger can raise the level for one window, one client or one category without raising it everywhere.

## Transport

- **Rings in shared memory.** Each source writes into its own fixed-size ring buffer in memory (suggestion: one per thread). Writing is copying a fixed-size record. No lock is shared with the reader.
- **Readers drain the ring.** A collector process (desktop side) maps the rings and reads from them. If it is slow or absent, the ring overwrites the oldest events and the writer counts what was lost. The next event after a loss is a "dropped N events" record, so gaps are never silent.
- **The recent past is always there.** Even with no debugger attached, the ring holds the last few seconds. When something goes wrong (a missed deadline, a crash, a key combination from the user), the collector saves the ring to a `.krkde` file: a flight recorder.
- **Files.** Recorded traces are `.krkde` files of the same records, with snapshots at intervals so a viewer can seek without reading from the start.

## State and snapshots

- Each source can send a snapshot of its state (the window model, the layer list, connected clients) on request and at intervals in a recording. Deltas follow, as the event publisher does today.
- A debugger can query the current state at any time. The answer is built from the same snapshot path and sent without blocking; the compositor never stops to answer.

## Record and replay

The core already takes time as a parameter (`now`) instead of reading a clock. To make whole sessions replayable (suggestion):

- **Inputs to the core are recorded completely:** input events, client requests that change the window model, desktop-service messages, output changes and the frame clock.
- **The core stays deterministic:** no hidden clock reads, no randomness, no iteration order that depends on addresses or hash seeds.
- **Replay** feeds the recording into the core in the simulator. It can step frame by frame, stop at an event, and compare its output (layer lists, frames) against the recording. A replay that differs points to non-determinism, which is itself a bug.
- Client pixels are not replayed. Their windows show captures where present, or placeholders.

## The debugger is a client

- The debugger runs as its own process and talks to the compositor only over the Kuroko protocol. It is a privileged client (like other Kuroko processes, never an arbitrary app).
- **Overlays are drawn by the compositor,** because only it can draw over other windows. The debugger sends what to show (outlines, labels, highlighted layers), and the compositor draws it as its own layer, marked as debug. Overlays follow the human-factors rules: nothing flashes more than 3 times per second, so damage is shown as outlines that fade, not as flashes.
- **A debugger that hangs or crashes changes nothing** for the compositor: it is one more subscriber that falls behind.

## Apps

- Apps built on Kuroko's widget library write to their own ring, in the same format, with the same clock: widget events, layout, their own frame stages. Their streams merge with the compositor's by time and cause.
- Other Wayland apps are seen from outside: krkwl's protocol trace, their commits and the frames that showed them.

## Privacy

Traces can hold what the user types and reads.

- **Typed text is not recorded by default.** Key events record that a key was pressed and its kind (letter, digit, modifier, navigation), not which letter. Full key recording is a separate, explicit switch, shown in the top bar while it is on.
- Window titles and file names are recorded, so saved traces follow the same at-rest rules as the history (Top-Level Design, "Sensitive like the history").
- Only Kuroko's own processes may attach a debugger or read the rings.

## What this means for the code now

Things to build in while the code is small, before the debugger exists:

- A trace module in `krkcore`: the record, the ring, the categories, the "dropped N" rule, with tests.
- A system-wide monotonic clock for all trace times (the simulator's clock is "since start" today).
- IDs for the objects that do not have one yet: Wayland clients, surfaces, buffers, layers, input events.
- Configure-to-commit cause tracking in krkwl.
- The layer list (GPU design) with IDs, names, owners and a hit test from the start.
- Determinism checks in the core's tests: the same inputs give the same layer lists.

## Open questions

- [ ] How the debugger organizes and shows the stream of messages (the user's design, to come).
- [ ] Ring size per source, and how many seconds the flight recorder keeps.
- [ ] Trace type IDs: one range for all, or a range per component?
- [ ] What triggers an automatic flight-recorder save (missed deadline, crash, a key combination).
- [ ] Whether replay needs app pixels: recorded captures, or placeholders only.
