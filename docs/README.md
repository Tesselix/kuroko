# Design documents

Copied from the claude.ai project "Tesselix - AI powered Desktop" on
2026-10-14. From now on, edit them here, in the repo, so code and design
change together.

| Document | What it covers |
| --- | --- |
| [top-level-design.md](top-level-design.md) | Architecture, binary format, memory safety, layout, launcher, switcher, chrome, shell. **Wins over the others.** |
| [widget-framework.md](widget-framework.md) | Widget library, Mode A and Mode B, protocol, widget model, data service |
| [look-and-controls.md](look-and-controls.md) | Look, scrolling, text fields, search field, date picker, keyboard |
| [human-factors.md](human-factors.md) | How people use a desktop: timing, choice, attention, motion, accessibility |
| [design-concept.md](design-concept.md) | The original vision: the AI-aware compositor |
| [tessel-store.md](tessel-store.md) | App trust, authorization, the Tessel Store |
| [debugging.md](debugging.md) | Debugging foundations: trace events, identity, causes, frames, record and replay |
| [user-signals.md](user-signals.md) | Clipboard history and trusted paste, sensitive windows, interest: the concepts and the facts Tesselix must provide for them |
| [implementation-notes.md](implementation-notes.md) | Decisions made in code where the documents leave a question open |
| [dependencies.md](dependencies.md) | The "latest solid version" rule and the versions in use |
| [zig-notes.md](zig-notes.md) | Std APIs of the pinned Zig version |
