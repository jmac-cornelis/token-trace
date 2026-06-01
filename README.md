# Token Trace

A native macOS menu bar app that locally aggregates token usage across OpenCode, Roo Code, OpenAI Codex, Openclaw gateway, and Continue.dev — with live summaries, per-project drilldowns, session-level history, and usage charts.

Think **iStat Menus for AI token usage**.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5.10](https://img.shields.io/badge/Swift-5.10-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Menu bar icon** with live token count
- **Today's total** with input/output breakdown
- **Per-source totals** — OpenCode, Roo Code, Codex, Openclaw, and Continue.dev tracked separately
- **Token type breakdown** — prompt, completion, cached, reasoning
- **Usage chart** — bar graph with 7D / 30D / 1Y / All range picker
- **Recent sessions** — expandable with per-session token details and descriptive titles
- **Day-by-day history** — expandable with in/out/cached breakdown, per-source totals, and session drilldown
- **Background polling** — refreshes every 5 seconds
- **Local-first** — all data stays on your machine, no network calls

## Architecture

```
OpenCode DB (read-only) ──→ OpenCodeReader ──┐
                                             │
Roo Code JSON (read-only) ──→ RooCodeReader ─┤
                                             ├→ CollectorService → SQLite → UsageStore → SwiftUI
Codex DB (read-only) ──→ CodexReader ────────┤
                                             │
Openclaw JSONL (read-only) ──→ OpenclawReader┤
                                             │
Continue DB (read-only) ──→ ContinueReader ──┘
```

Three-layer design:

| Layer | Purpose |
|---|---|
| **Readers** | Read-only access to source tool databases/files |
| **Collector + Store** | Background polling, normalization, aggregation |
| **Views** | SwiftUI MenuBarExtra with rich dropdown and charts |

### Data Sources

**OpenCode** — Reads from `~/.local/share/opencode/opencode.db` (SQLite, read-only). Extracts token counts from the `message` table's JSON `data` column using `json_extract()`. Joins with `session` and `project` tables for context. Fields: input, output, reasoning, cache read/write.

**Roo Code** — Reads from `~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks/`. Parses `_index.json` for task metadata and per-task `ui_messages.json` for request-level token data. Computes deltas from cumulative counters. Fields: tokensIn, tokensOut, cacheWrites, cacheReads.

**OpenAI Codex** — Reads from `~/.codex/state_5.sqlite` (SQLite, read-only). Shared by both the Codex CLI and the Codex VS Code extension (they use the same database). Extracts `tokens_used` from the `threads` table, plus session title, working directory, model, and git info. Also parses rollout JSONL files from `~/.codex/sessions/` for per-turn `output_tokens` and `reasoning_output_tokens` breakdown when available.

**Openclaw** — Reads session transcript JSONL files from `/tmp/agents/{agentId}/sessions/`. Openclaw is a local AI gateway proxy that logs each LLM response with `usage: {input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, total_tokens, cost}`. Cursor-based incremental reads using file offset tracking.

**Continue.dev** — Reads from `~/.continue/dev_data/devdata.sqlite` (SQLite, read-only). Continue is a VS Code and JetBrains extension that logs each generation to the `tokens_generated` table (`model`, `provider`, `tokens_prompt`, `tokens_generated`, `timestamp`). Cursor-based incremental reads using the monotonic auto-increment `id`. Continue does not persist cost, cache, or project/session metadata, so those fields remain empty (cost is derived later via `CostEstimator`).

### Storage

Token Trace maintains its own normalized SQLite database at `~/Library/Application Support/TokenTrace/token-trace.db` with WAL mode for concurrent read/write. Source databases are never modified.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.10+
- One or more supported AI tools installed (app works with any combination)

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

## Testing

Requires Xcode (for the Swift Testing framework):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
cd TokenTrace
swift test
```

69 tests across 6 suites covering database operations, all five readers, formatting, and model logic.

## Project Structure

```
TokenTrace/
├── Package.swift
├── Info.plist
├── Sources/TokenTrace/
│   ├── TokenTraceApp.swift              # App entry point, MenuBarExtra setup
│   ├── Models/
│   │   ├── UsageEvent.swift             # Core event model (GRDB-backed)
│   │   ├── SessionSummary.swift         # Aggregated session display model
│   │   ├── DailySummary.swift           # Per-day aggregation model
│   │   ├── ChartDataPoint.swift         # Chart data + ChartRange enum
│   │   └── SourceHealth.swift           # Source health + ReaderError
│   ├── Services/
│   │   ├── DatabaseManager.swift        # Our SQLite DB (schema, queries, charts)
│   │   ├── UsageStore.swift             # Observable state for UI
│   │   ├── CollectorService.swift       # Background polling orchestrator
│   │   ├── TokenFormatter.swift         # Token count + relative time formatting
│   │   └── Readers/
│   │       ├── OpenCodeReader.swift     # Reads OpenCode's SQLite DB
│   │       ├── RooCodeReader.swift      # Reads Roo Code's JSON files
│   │       ├── CodexReader.swift        # Reads Codex CLI/extension SQLite + JSONL
│   │       ├── OpenclawReader.swift     # Reads Openclaw gateway JSONL transcripts
│   │       └── ContinueReader.swift     # Reads Continue.dev's SQLite DB
│   └── Views/
│       ├── MenuBarDropdown.swift        # Main dropdown UI
│       ├── MenuBarIcon.swift            # Menu bar label
│       └── UsageChartView.swift         # Swift Charts bar graph with range picker
└── Tests/TokenTraceTests/
    ├── DatabaseManagerTests.swift       # 14 tests: insert, queries, cursors, charts
    ├── OpenCodeReaderTests.swift        # 8 tests: fetch, cursor, health, mock DB
    ├── RooCodeReaderTests.swift         # 7 tests: deltas, cursor, fields, health
    ├── OpenclawReaderTests.swift        # 13 tests: JSONL parsing, cursor, multi-agent
    ├── ContinueReaderTests.swift        # 6 tests: fetch, cursor, timestamp, health
    └── FormatTests.swift                # 10 tests: formatting, display names, models
```

## How Token Counting Works

Token Trace does not count tokens itself. It reads the token counts that your AI tools already recorded locally.

When you use any supported tool, every LLM API call returns a `usage` field in the response (standard across OpenAI, Anthropic, and other providers). The tools capture these provider-reported counts and store them on disk:

- **OpenCode** stores them in a SQLite database (`~/.local/share/opencode/opencode.db`). Each assistant message has a JSON `data` column containing `tokens: {total, input, output, reasoning, cache: {read, write}}`. We query these with `json_extract()`, joined with session and project tables for context.

- **Roo Code** stores them in JSON files under VS Code's global storage (`~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks/`). Each task directory has a `ui_messages.json` where `api_req_started` events contain `{tokensIn, tokensOut, cacheWrites, cacheReads}`. These values are cumulative within a task, so we compute deltas between consecutive entries to get per-request counts.

- **OpenAI Codex** stores a `tokens_used` total per thread in `~/.codex/state_5.sqlite`. For granular breakdown, rollout JSONL files in `~/.codex/sessions/` contain per-turn `output_tokens` and `reasoning_output_tokens`. Both the CLI and VS Code extension share this database.

- **Openclaw** logs each proxied LLM response as a JSONL line in `/tmp/agents/{agentId}/sessions/{sessionId}.jsonl`. Each assistant message includes `usage: {input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, total_tokens, cost}`.

- **Continue.dev** stores them in a SQLite database (`~/.continue/dev_data/devdata.sqlite`), shared across its VS Code and JetBrains extensions. Each generation is appended to the `tokens_generated` table with `{model, provider, tokens_prompt, tokens_generated, timestamp}`. We read new rows incrementally by tracking the auto-increment `id`. Continue does not record cost, cache, or project metadata, so prompt and completion tokens are the only counts available.

Token Trace polls these sources every 5 seconds, normalizes the data into a common format, and writes it to its own SQLite database for aggregation and display.

### Is this guaranteed to be only my tokens?

Yes. Token Trace reads exclusively from local files on your machine:

- All source paths are user-local directories
- OpenCode's, Codex's, and Continue's databases are opened with `readonly = true` — we never write to them
- Roo Code's and Openclaw's files are read via standard file I/O — never modified
- Token Trace makes **zero network calls** — no HTTP, no sockets, no telemetry
- Our own database lives at `~/Library/Application Support/TokenTrace/token-trace.db`

Any usage from other machines, other users, or API calls made outside of these tools will not appear here. This is strictly what the tools logged locally on your machine.

## Privacy

- No prompts or completions are stored — only token count metadata
- No network calls — everything is local
- Source databases are opened read-only
- Your data never leaves your machine

## Roadmap

- [ ] Cost estimation with configurable pricing
- [ ] CSV/JSON export
- [ ] Per-project comparison views
- [ ] Session timeline
- [ ] Daily/weekly rollup notifications
- [ ] LaunchAgent for auto-start

## License

MIT
