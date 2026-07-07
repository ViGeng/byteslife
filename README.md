# ByteLife (working title)

ByteLife is a native macOS app that tracks the digital side of a person's existence, centered on the concept of bytes. It aggregates AI token usage, network traffic, disk activity, screen time, and physical input into one dashboard of digital life.

Version 0.5.0 is implemented and running. The menubar shows today's running balance, and the dropdown is the Byte Flow deck: a chart-led live dashboard that adapts to the system appearance (a dark instrument in dark mode, a light one in light mode), with a hero flow chart of the last half hour (network and disk on one shared scale), a gradient sparkline and glowing live rate per channel in its own signal color, an attention ring, a prompted-versus-generated token ratio bar, and a hex ticker printing real inter-poll byte deltas. The Ledger remains the record layer underneath. The General Ledger window is the Back Office: a periods sidebar whose rows carry per-day token and byte activity minis plus a pinned all-time summary, and a day dashboard with a 24-hour flow chart, per-account cards with hourly activity bars, and the day's receipt below. The Reconcile ritual closes each day into an immutable receipt rendered as a real thermal strip (torn edges, a barcode drawn from its SHA-256 content hash) that shares to the system share sheet or saves as PNG or vector PDF. The concept brief below and the research under docs/ remain the design ground truth.

## Premise

We are carbon-based lifeforms, but our digital existence has become vital. ByteLife measures that existence through five metric families:

- AI usage counts the tokens consumed and generated across the user's AI tools.
- Network activity counts the total bytes sent and received.
- Disk activity counts the total bytes read and written.
- Screen time counts the hours spent in front of an awake display.
- Input counts total keystrokes and cumulative mouse travel distance.

## Why this app can exist (landscape, July 2026)

A market scan found that no existing tool unifies AI token tracking with system-level byte metrics. The AI usage trackers, such as Tokens 4 Breakfast and ccusage, cover only tokens. The system monitors, such as iStat Menus and the open-source Stats app, are live-only and AI-blind. WhatPulse is the closest analog for input and network tracking, but it has no disk history, no AI awareness, and no native Mac feel. The pricing norm in this niche is a one-time purchase between roughly 8 and 20 dollars, and subscription fatigue is a documented reason users abandon utilities of this size.

ByteLife's defensible position is the single-currency framing: every metric family is reported in or alongside literal byte counts, under one conceptual frame, in a native Swift app. Details live in [docs/research/landscape.md](docs/research/landscape.md).

## Creative direction (recommended): the Ledger

Five directions were developed and scored by a three-judge panel on desirability, conceptual honesty, and buildability. The Ledger ("Double-Entry Self") won overall because it never scored below 8 on any lens. Full concept sheets are in [docs/research/concepts.md](docs/research/concepts.md) and the scoring is in [docs/research/judges.md](docs/research/judges.md).

The Ledger treats your digital life as a small estate and installs you as its accountant. The frame is honest rather than decorative, because three of the five families really are paired directional flows. Network traffic pairs bytes sent against bytes received, disk activity pairs writes against reads, and AI usage pairs tokens prompted against tokens generated, so debit and credit columns are the data's native shape. Screen time and input do not pair, and the design books them frankly as expense accounts named Hours Under the Lamp and the Labor Account instead of faking a balance.

The core habit loop is Reconciliation. At the end of each day the user closes the books with one click. The app freezes the period, prints a receipt-styled summary of the five accounts, adds one dry margin comment, and stamps the day BALANCED in brass gold. Reconciled days become immutable and accumulate into a browsable, auditable history of the user's digital life.

The voice is a competent, faintly weary bookkeeper with dry wit and no moralizing. The visual language is ledger paper and ink: IBM Plex Mono for figures with tabular numerals, oxblood red debits, muted ledger-green credits, and a single brass-gold accent reserved for the balanced stamp.

The following ideas are grafted in from the losing directions:

- The daily Dispatch from the Almanac direction adds one composed observation per day that names a non-obvious relationship, for example that you generated more words with machines than you typed by hand for the first time this week.
- Per-account calibration from the Instrument direction lets the user set a personal normal range so heavy and light users both get expressive readings.
- The "accounts not yet opened" and "partial: 1 of N sources reporting" states handle missing data sources as honest disclosure rather than broken UI.
- The generated-to-prompted token ratio from the Digital Metabolism direction is surfaced as the one AI metric that carries genuine self-knowledge.
- A tamper-evident content hash on each daily receipt makes the privacy promise verifiable rather than merely stated.
- The year-end Annual Report compiles the daily closes into a bound, PDF-exportable keepsake.

The runner-up directions remain documented. Symbiont, a living cell that metabolizes your bytes, scored highest on shareability but is a multi-month graphics project. The Instrument, a precision bench meter, is the most buildable alternative but risks being admired for a week and then ignored.

## Feasibility summary (macOS 14+)

| Family | v1 data source | Permission |
| --- | --- | --- |
| AI tokens | Parse Claude Code JSONL transcripts and Codex CLI session logs locally | None outside the sandbox |
| Network | sysctl NET_RT_IFLIST2 64-bit interface counters | None |
| Disk | IOKit IOBlockStorageDriver statistics, plus proc_pid_rusage per process | None |
| Screen time | Idle-time checks plus NSWorkspace sleep, wake, and lock notifications | None |
| Input | Listen-only CGEventTap that increments counters and discards key codes | Input Monitoring |

The key facts from the research, detailed in [docs/research/feasibility.md](docs/research/feasibility.md), are these:

- Only input tracking requires a permission prompt, and the app should request Input Monitoring rather than the broader Accessibility permission.
- AI tokens have no OS API. The Anthropic and OpenAI usage APIs are confirmed unavailable to individual accounts, so local log parsing is the only viable path for most users. Claude Code transcripts need deduplication because duplicate usage lines were observed empirically. Cursor and GitHub Copilot cannot provide token counts at all, and Ollama keeps no logs, so it would need a local loopback proxy.
- Distribution should start with Developer ID plus notarization. The Mac App Store is possible later, but it adds folder-grant friction for reading log directories and carries real review risk around keystroke counting under guideline 2.4.5(v).
- Secure Input means typing in password fields is never observable, by OS design, so keystroke counts will slightly undercount.
- All five collectors are cheap. File watching is event-driven, the counters are single syscalls polled every few seconds, and the event tap does microseconds of work per event.

## Design principles

- The app is local-first and records counts, never contents. Version 1 ships without any network client so there is nothing to phone home with, and users are invited to verify that with Little Snitch.
- The voice stays neutral. The app reports raw counts and never issues a productivity score, because judgment is a documented abandonment driver.
- Each day leads with one clear number to avoid dashboard overload.
- Missing sources degrade gracefully into visible, honest states instead of empty panels.
- If commercialized, pricing follows the one-time-purchase norm of the niche.

## Version 1 scope

- A menubar extra shows today's running balance and drops down the live five-channel view. (Implemented as the Byte Flow dashboard, with live rates, charts, and rolling figures while the panel is open.)
- A General Ledger window holds the posted history and the trial balance. (Implemented.)
- The nightly Reconcile ritual produces the daily receipt. (Implemented: BALANCED in brass, FLAGGED with the short accounts named, or POSTED IN ARREARS for a past day closed late.) The weekly Statement is not yet built.
- Data collectors cover the five families listed in the feasibility table. (Implemented.)
- Version 1 deliberately omits cloud sync, accounts, goals, streaks, social features, per-app network attribution, and any iOS companion.

## Beyond one Mac (designed, not yet built)

[docs/design/multi-device.md](docs/design/multi-device.md) records the multi-device direction: every machine is a holding with a stable identity, device-own metrics merge additively across holdings, shared sources attribute to the source rather than the observer, and remote servers are collected agentlessly over existing SSH access with nothing installed on the remote side.

## Building and running

The package needs macOS 14+ and a Swift 6 toolchain. `swift build` and `swift test` cover the core library (81 tests). `scripts/package-app.sh` produces an ad-hoc-signed `dist/ByteLife.app` that lives in the menubar with no Dock icon.

On first launch, four collectors run immediately with no permission prompts. Input counting stays in a visible "needs permission" state until Input Monitoring is granted from the panel, because the app never raises the prompt on its own. The AI collector backfills token history from existing Claude Code transcripts under `~/.claude/projects` into the correct historical days, deduplicated by the `(sessionId, message.id, requestId)` key. Data lands in `~/Library/Application Support/ByteLife/bytelife.sqlite`.

## Repository layout

- [README.md](README.md) holds the current concept brief and project state, updated each iteration.
- [PLAN.md](PLAN.md) is the v1 scaffold plan, now executed, with post-execution deviations recorded in its status section.
- [CHANGELOG.md](CHANGELOG.md) is the append-only iteration log.
- [Sources/ByteLifeCore/](Sources/ByteLifeCore/) is the library with all logic: the model layer, the SQLite store, the collector framework, and the five collectors.
- [Sources/ByteLifeApp/](Sources/ByteLifeApp/) is the thin menubar app shell.
- [Tests/ByteLifeCoreTests/](Tests/ByteLifeCoreTests/) holds the test suite and the hand-authored transcript fixtures.
- [scripts/package-app.sh](scripts/package-app.sh) assembles and ad-hoc-signs `dist/ByteLife.app`.
- [docs/design/](docs/design/) holds forward design notes, currently the multi-device and remote-source design.
- [docs/research/](docs/research/) holds the raw output of the 2026-07-04 concept workflow: feasibility research, the landscape scan, the five concept sheets, and the judge panel results.

## Decisions so far (2026-07-04)

- Version 1 is a menubar-first app: a status item whose click opens a panel with the day's statistics.
- Distribution is Developer ID with notarization, outside the Mac App Store.
- The architecture is a core plus per-metric collectors: one resident menubar process hosting in-process Swift collector modules behind a shared protocol, each with its own availability state (running, permission denied, or source missing), all writing normalized samples into a local SQLite store with hourly and daily rollups. The AI collector internally hosts per-tool source adapters (Claude Code first, then Codex, later an optional Ollama loopback proxy). A data-level ingestion point for external scripts is deferred to v1.1, and no dynamic plugin loader is planned until there is demand.

## Open questions

- The final app name. Current candidates in the Ledger direction include Reconcile, Bytekeeping, Nightaudit, and The Standing Ledger, with ByteLife still viable as the umbrella brand.
- Whether version 1 targets personal use or a public release from day one.

The creative direction question is settled: the Ledger was committed to and applied in iteration 3.
