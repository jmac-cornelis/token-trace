# Token Trace

A native macOS menu bar app that locally aggregates token usage across OpenCode, Roo Code, and AI gateways — with live summaries, per-project drilldowns, and session-level history.

Think **iStat Menus for AI token usage**.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5.10](https://img.shields.io/badge/Swift-5.10-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Menu bar icon** with live token count
- **Today's total** with input/output breakdown
- **Per-source totals** — OpenCode and Roo Code tracked separately
- **Token type breakdown** — prompt, completion, cached, reasoning
- **Recent sessions** — expandable with per-session token details
- **Background polling** — refreshes every 5 seconds
- **Local-first** — all data stays on your machine, no network calls

## Architecture

```
OpenCode DB (read-only) ──→ OpenCodeReader ──┐
                                             ├→ CollectorService → SQLite → UsageStore → SwiftUI
Roo Code JSON (read-only) ──→ RooCodeReader ─┘
```

Three-layer design:

| Layer | Purpose |
|---|---|
| **Readers** | Read-only access to source tool databases/files |
| **Collector + Store** | Background polling, normalization, aggregation |
| **Views** | SwiftUI MenuBarExtra with rich dropdown |

### Data Sources

**OpenCode** — Reads directly from `~/.local/share/opencode/opencode.db` (SQLite). Extracts token counts from the `message` table's JSON `data` column using `json_extract()`. Joins with `session` and `project` tables for context.

**Roo Code** — Reads from `~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks/`. Parses `_index.json` for task metadata and per-task `ui_messages.json` for request-level token data. Computes deltas from cumulative counters.

### Storage

Token Trace maintains its own normalized SQLite database at `~/Library/Application Support/TokenTrace/token-trace.db` with WAL mode for concurrent read/write. Source databases are never modified.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.10+
- OpenCode and/or Roo Code installed (app works with either or both)

## Build & Run

```bash
cd TokenTrace
swift build
swift run
```

The app appears in your menu bar — no dock icon. Click the icon to see the dropdown.

To run in the background:

```bash
cd TokenTrace
swift build -c release
.build/release/TokenTrace &
```

## Project Structure

```
TokenTrace/
├── Package.swift
├── Info.plist
└── Sources/TokenTrace/
    ├── TokenTraceApp.swift          # App entry point, MenuBarExtra setup
    ├── Models/
    │   ├── UsageEvent.swift         # Core event model (GRDB-backed)
    │   ├── SessionSummary.swift     # Aggregated session display model
    │   └── SourceHealth.swift       # Source health + ReaderError
    ├── Services/
    │   ├── DatabaseManager.swift    # Our SQLite DB (schema, queries)
    │   ├── UsageStore.swift         # Observable state for UI
    │   ├── CollectorService.swift   # Background polling orchestrator
    │   └── Readers/
    │       ├── OpenCodeReader.swift # Reads OpenCode's SQLite DB
    │       └── RooCodeReader.swift  # Reads Roo Code's JSON files
    └── Views/
        ├── MenuBarDropdown.swift    # Main dropdown UI
        └── MenuBarIcon.swift        # Menu bar label
```

## Privacy

- No prompts or completions are stored — only token count metadata
- No network calls — everything is local
- Source databases are opened read-only
- Your data never leaves your machine

## Roadmap

- [ ] Gateway log parser
- [ ] Cost estimation with configurable pricing
- [ ] Dashboard window with charts
- [ ] CSV/JSON export
- [ ] Per-project comparison views
- [ ] Session timeline
- [ ] Daily/weekly rollup notifications
- [ ] LaunchAgent for auto-start

## License

MIT
