# ByteLife (working title)

ByteLife is a planned native macOS app that tracks the digital side of a person's existence, centered on the concept of bytes. It aggregates AI token usage, network traffic, disk activity, screen time, and physical input into one dashboard of digital life.

The project is in the concept phase. This repository contains design and research documents only. There is no code yet.

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

## Version 1 scope sketch

- A menubar extra shows today's running balance and drops down a five-account day sheet.
- A General Ledger window holds the posted history and the trial balance.
- The nightly Reconcile ritual produces the daily receipt, and a weekly Statement rolls seven days up.
- Data collectors cover the five families listed in the feasibility table.
- Version 1 deliberately omits cloud sync, accounts, goals, streaks, social features, per-app network attribution, and any iOS companion.

## Repository layout

- [README.md](README.md) holds the current concept brief and is updated each iteration.
- [PLAN.md](PLAN.md) is the approved implementation plan for the v1 scaffold, written to be executed on the development Mac.
- [CHANGELOG.md](CHANGELOG.md) is the append-only iteration log.
- [docs/research/](docs/research/) holds the raw output of the 2026-07-04 concept workflow: feasibility research, the landscape scan, the five concept sheets, and the judge panel results.

## Decisions so far (2026-07-04)

- Version 1 is a menubar-first app: a status item whose click opens a panel with the day's statistics.
- Distribution is Developer ID with notarization, outside the Mac App Store.
- The architecture is a core plus per-metric collectors: one resident menubar process hosting in-process Swift collector modules behind a shared protocol, each with its own availability state (running, permission denied, or source missing), all writing normalized samples into a local SQLite store with hourly and daily rollups. The AI collector internally hosts per-tool source adapters (Claude Code first, then Codex, later an optional Ollama loopback proxy). A data-level ingestion point for external scripts is deferred to v1.1, and no dynamic plugin loader is planned until there is demand.

## Open questions

- Which creative direction to commit to. The Ledger is recommended, with Symbiont as the bold alternative, and the core can be built skin-agnostic in the meantime.
- The final app name. Current candidates in the Ledger direction include Reconcile, Bytekeeping, Nightaudit, and The Standing Ledger, with ByteLife still viable as the umbrella brand.
- Whether version 1 targets personal use or a public release from day one.
