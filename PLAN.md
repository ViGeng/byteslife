# ByteLife v1 scaffold: implementation plan

Status: executed on the development Mac on 2026-07-07 (see CHANGELOG.md, iteration 2). This plan was authored on 2026-07-04 on a planning machine with Command Line Tools only. The grounding research lives in [docs/research/](docs/research/), especially [feasibility.md](docs/research/feasibility.md).

Deviations from the letter of the plan, recorded after execution: the mouse channel is named inputMouseMilliPixels; the input permission recheck is a 10-second timer rather than an app-foreground hook, because an accessory menubar app has no conventional foreground moment; the disabled availability state is reserved but not yet reachable in v1; and a DayBucket helper file was added to the Store layer so the write and read paths share one bucketing rule. A post-implementation review pass hardened the scaffold beyond the plan: AI ingest commits dedup keys, samples, and file offsets in one SQLite transaction; transcript watchers tear down on delete and rename; network and disk baselines advance only after their deltas commit; and the event-tap session recovers from creation failure instead of reporting a false running state.

## Context

ByteLife is a native macOS menubar app tracking five "byte" metric families: AI tokens, network traffic, disk activity, attentive screen time, and input (keystrokes and mouse travel). The agreed architecture is one resident menubar process, in-process collector modules behind a shared protocol, SQLite storage, and a deliberately skin-agnostic minimal UI (the Ledger visual direction from the concept phase is applied later). Claude Code token consumption is a first-class requirement of version 1.

## Key decisions

- The project is a Swift Package: swift-tools-version 6.0, platform macOS 14+, zero external dependencies. SQLite comes from the system `import SQLite3` module with `.linkedLibrary("sqlite3")`. Xcode opens Package.swift directly on the dev Mac.
- Targets use Swift language mode v5 for now, because C callbacks such as the CGEventTap fight Swift 6 strict concurrency. Upgrading to v6 mode is a later, deliberate migration.
- Concurrency model: each collector owns one serial DispatchQueue. `SampleStore` is a final class guarded by its own serial queue rather than an actor, so C callbacks and timer handlers can call it synchronously. The input collector owns a dedicated Thread running a CFRunLoop for its event tap.
- All logic lives in the `ByteLifeCore` library target so `swift test` covers it. The `ByteLifeApp` executable is a thin AppKit/SwiftUI shell.
- Collectors emit already-reduced additive deltas. The store only accumulates deltas into minute buckets, which keeps one uniform schema for counter-derived sources (network, disk) and event-derived sources (input, AI, screen).

## File tree to create

```
Package.swift
.gitignore                      (.build/, *.app, .DS_Store, dev *.sqlite*)
Sources/ByteLifeApp/
  main.swift                    entry: builds AppCoordinator, .accessory policy, runs app
  AppCoordinator.swift          wires store + registry + collectors + view model
  MenuBarView.swift             MenuBarExtra scene + panel (5 families, totals, status)
  DashboardViewModel.swift      @MainActor; polls store every ~2s for today's rollups
  PermissionsHint.swift         deep link to the Input Monitoring settings pane
Sources/ByteLifeCore/
  Model/       MetricFamily, MetricKind, Sample, Availability, ByteFormatting
  Store/       SampleStore, SQLiteError, Migrations
  Collector/   Collector (protocol), CollectorRegistry, CounterAccumulator, Scheduler
  Collectors/  NetworkCollector, DiskCollector, ScreenCollector, InputCollector
  Collectors/AI/ AICollector, AIUsageSource, ClaudeCodeSource, ClaudeCodeParser
  System/      NetworkInterfaces, DiskStatistics, IdleTime, FileTailer
Tests/ByteLifeCoreTests/
  ClaudeCodeParserTests, DedupTests, SampleStoreTests,
  CounterAccumulatorTests, ByteFormattingTests
  Fixtures/claude_sample.jsonl, claude_rotated.jsonl
scripts/package-app.sh          release build -> ByteLife.app (LSUIElement) + ad-hoc codesign
```

## Core design points

- The `Collector` protocol exposes `id`, `family`, `availability` (running, needsPermission, sourceMissing, or disabled), `start()`, `stop()`, and an `onAvailabilityChange` callback. The registry aggregates availability for the UI.
- `Sample(family, kind, value: Int64, timestamp)`. MetricKind channels: networkBytesIn/Out, diskBytesRead/Written, aiInput/Output/CacheCreation/CacheReadTokens, screenAttentiveSeconds, inputKeystrokes, inputMouseDistance (stored as milli-pixels in Int64).
- SQLite schema v1, opened with WAL, synchronous=NORMAL, busy_timeout, and user_version migrations:
  - `samples(day_epoch, minute, kind, value, PRIMARY KEY(day_epoch, minute, kind)) WITHOUT ROWID`, written with UPSERT accumulate (`value = value + excluded.value`).
  - `meta(key, ival, sval)` holds per-interface and per-disk counter baselines plus AI per-file byte offsets and inodes, so restarts never double count.
  - `ai_seen(dedup_key, day_epoch)` is the persisted AI dedup ledger, pruned by age on open.
- `CounterAccumulator.delta(previous:current:)` is the heart of counter correctness. A nil previous baselines silently. A decrease is treated as a reset (reboot or device re-enumeration) and re-baselines rather than emitting a wrapped huge value.
- NetworkCollector polls sysctl NET_RT_IFLIST2 every ~3s, parsing if_msghdr2 with embedded if_data64 for 64-bit counters. Baselines are per interface, never on the summed total, so a vanished interface (VPN down, USB ethernet unplugged) is not misread as a global reset. Known v1 imprecision: utun plus physical interfaces can double-count tunneled traffic.
- DiskCollector enumerates IOMedia, walks parents to IOBlockStorageDriver, and reads "Bytes (Read)" and "Bytes (Write)" from the Statistics dictionary every ~3s. Drivers are deduplicated by registry entry ID because APFS partitions share one driver. Every IOKit object must be released.
- ScreenCollector runs an attentive/inactive state machine: idle threshold via CGEventSourceSecondsSinceLastEventType (30s tick, 300s threshold), NSWorkspace sleep/wake/session notifications, and DistributedNotificationCenter screenIsLocked/Unlocked (undocumented, so the idle path is the resilient floor). Accumulation uses a monotonic clock so sleep gaps are never counted, and each emitted delta is bucketed at emission time so overnight sessions split across days correctly.
- InputCollector gates on CGPreflightListenEventAccess and CGRequestListenEventAccess (Input Monitoring, never Accessibility). It is a listen-only CGEventTap counting keyDown events and accumulating mouse move/drag hypot deltas in a top-level C callback that never reads keycodes. It re-enables on tapDisabledByTimeout, drains counters to the store on a 5s timer, and re-checks permission on app foreground to catch revocation.
- ClaudeCodeSource watches ~/.claude/projects with DispatchSource vnode watchers plus directory-level discovery of new session files. FileTailer resumes from persisted byte offsets and parses only complete lines. Truncation or an inode change resets the offset to 0, and dedup prevents re-counting. The dedup key is `(sessionId, message.id, requestId)`. This was verified empirically: 171 usage-bearing lines in a live transcript collapse to 50 distinct pairs, and the top-level `uuid` is unique per line, so keying on uuid would defeat dedup entirely. The `AIUsageSource` protocol leaves room for a Codex CLI adapter later (its cumulative token_count semantics differ).
- The UI is a minimal panel with five rows: family name, today's formatted total, and an availability badge. No visual skin yet.

## Execution order (each step ends in a compiling state)

1. Package.swift, skeleton targets, .gitignore. `swift build` green. Commit.
2. Model layer plus ByteFormattingTests. `swift test` green.
3. SampleStore, Migrations, SampleStoreTests against a temp-file database.
4. CounterAccumulator plus tests (baseline, increase, decrease-as-reset).
5. Collector protocol, Scheduler, CollectorRegistry, plus a fake-collector registry test.
6. AI chain: ClaudeCodeParser, FileTailer, ClaudeCodeSource, AICollector, hand-authored fixtures (normal, duplicate-usage pair, non-assistant line, rotation case), ClaudeCodeParserTests, DedupTests. This is the highest-value tested surface.
7. System readers (NetworkInterfaces, DiskStatistics, IdleTime) with shape-only smoke tests. sysctl and IOKit disk statistics need no TCC permission, so they return real data even on a machine without Xcode.
8. Live collectors wiring readers into schedulers, baselines, and the store.
9. UI shell: MenuBarView, DashboardViewModel, AppCoordinator, main.swift.
10. scripts/package-app.sh, then chmod +x.

## Verification

Anywhere with a Swift toolchain: `swift build`, `swift build -c release`, and `swift test` must be green. That covers the parser, dedup, rollups, accumulator, formatting, registry, and compile-correctness of the live collectors.

Only on the dev Mac with a full GUI session and the packaged .app: the Input Monitoring TCC prompt flow (grants bind to the bundled, signed identity, so `swift run` does not exercise them), event tap delivery and timeout re-enable, sleep/wake/lock notifications, menubar rendering with the .accessory policy, the disk parent-walk across real disk configurations, and the end-to-end check that totals climb in the panel while typing, moving data, and using Claude Code.

## Accepted risks

- `import SQLite3` under a CLT-only toolchain is high confidence but must be confirmed in step 1. The fallback is a tiny system-library module map target, still with zero external dependencies.
- Secure Input undercounts keystrokes by OS design. Network counters are quantized for third-party readers on some macOS versions. Day boundaries are naive local midnight in v1, with no special timezone or DST handling.

---

# Iteration 3: the Ledger experience

Status: executed 2026-07-07 (see CHANGELOG.md, iteration 3). Deviations recorded after execution: a third receipt stamp, POSTED IN ARREARS, was added beyond the concept sheet's two, because closing a past day from the General Ledger cannot honestly print BALANCED or FLAGGED when collector availability for that period was not retained; the arrears receipt discloses this instead. The panel gained the dynamic behavior requested during the iteration: it refreshes the moment it opens, figures roll to new values with a numeric transition (the concept's split-flap tick), polling runs at two seconds while the panel is open, and drops to thirty seconds when closed. Brass gold is gated strictly to BALANCED in every surface. Multi-device and agentless SSH collection were designed (not built) in [docs/design/multi-device.md](docs/design/multi-device.md). The authoritative creative spec is the "Double-Entry Self" concept sheet in [docs/research/concepts.md](docs/research/concepts.md) (lines 85-103) plus the grafts listed in README.md. This iteration applies the Ledger skin, the Reconcile ritual with the receipt artifact, and the General Ledger window.

## Decisions

- Accounts and sides follow the concept sheet's VOCAB exactly. The rule is: what flows out of you posts as a debit, what comes back posts as a credit. Token Account books Tokens Payable (prompted, debit; aiInputTokens + both cache-creation and cache-read booked as a separate memo line, see below) against Tokens Receivable (generated, credit; aiOutputTokens), with a generated-to-prompted "exchange rate" footnote. Traffic Account books Bytes Remitted (sent, debit) against Bytes Received (credit). Storage Account books Writes Posted (debit) against Reads Drawn (credit) plus a derived churn line. Hours Under the Lamp is a single-debit expense account in HH:MM. The Labor Account is an expense account with Keys Struck (count) and Distance Hauled (mouse travel in meters).
- Cache tokens are not silently summed into Tokens Payable, because cache reads dwarf real prompting by orders of magnitude and would destroy the exchange-rate footnote's meaning. The account body shows prompted vs generated; a small memo line reports cache traffic separately and honestly.
- Mouse milli-pixels convert to meters at an assumed 220 pixels per inch (Retina-class), recorded as an assumption in code.
- The menubar shows a glyph plus today's running balance, defined as the day's posted byte volume: the sum of Traffic and Storage debits and credits. Tokens, hours, and labor keep their own units and never fold into that figure.
- Palette per the concept sheet: paper #F4F1E9 (light) / ink-navy #141A24 (dark), debit oxblood #9B3B2F, credit ledger-green #3B6B4A, balance ink #1C1C1A, hairline pencil-gray #C9C2B2, brass gold #B58A3C reserved exclusively for the BALANCED stamp. Figures use the system monospaced font with tabular numerals; bundling IBM Plex Mono is deferred.
- Reconciliation: schema v2 adds `reconciliations(day_epoch INTEGER PRIMARY KEY, closed_at INTEGER, receipt_text TEXT, content_hash TEXT, stamp TEXT, comment TEXT)`. The receipt text is composed once, stored verbatim as the immutable artifact, and re-rendered from storage ever after. The content hash is SHA-256 (CryptoKit) over the canonical receipt body, printed truncated to 16 hex characters in the footer. The stamp is BALANCED when every collector reported .running at close, else FLAGGED with a plain note naming the short account(s). A day can be reconciled exactly once; past unposted days can be posted from the General Ledger window.
- The margin comment comes from a deterministic local rule engine (no AI dependency): rules compare the day against the trailing seven recorded days (largest account by churn, variance beyond a threshold, generated-vs-typed firsts, quiet days), each rule yields a dry bookkeeper sentence, the highest-priority applicable rule wins, and ties break deterministically. This same engine is the Dispatch graft.
- The General Ledger window is a document-style window: left rail with the five accounts, center column listing recorded days newest-first with their stamp state, day detail showing the stored receipt strip for posted days or a day sheet with a Close-the-books action for unposted ones, right rail with the all-history trial balance.
- Panel footer gains a launch-at-login toggle (SMAppService) and the existing Quit; version bumps to 0.2.0.
- Deferred to later iterations: the weekly Statement, the Annual Report, desktop widgets, the screensaver, per-account calibration and budget lines, and bundling IBM Plex Mono.

## Migration caution

The live database on this machine already holds v1 data (29 days of AI backfill plus live counters). The v2 migration must be additive only and must be proven against a copy of a populated v1 store in tests.

---

# Iteration 4: the live dashboard panel

Status: executed 2026-07-07, through three design passes driven by founder feedback: first the Instrument meter bridge ("dashboard like"), then a byte-native cell-lattice direction ("fancy, more bytes themed"), and finally the shipped chart-led Byte Flow deck ("some charts / visual elements"). The Ledger stays underneath as the record layer throughout: Reconcile, the paper receipt strip, and the General Ledger window are unchanged — the panel reads live, the books keep the record. The channel semantics come from the Instrument concept sheet in [docs/research/concepts.md](docs/research/concepts.md) (lines 25-43); the shipped visual design is the Byte Flow deck below.

## Decisions

- Channels per the Instrument VOCAB: TRAFFIC (bytes/s), STORAGE (bytes/s), COGNITION (tokens/min), EXPOSURE (accumulating attentive time, not a rate), MECHANICS (keystrokes/min plus the distance odometer). Each channel shows a drawn segment-bar meter of recent history, a live rate readout, a small sub-line with today's directional totals, and a peak-hold mark.
- Live rates come from successive view-model polls: the panel already fetches today's totals every 2 seconds while open, so rate = delta between snapshots over elapsed time, smoothed with a light exponential moving average. No collector or store-write changes.
- History bars read the store's existing minute buckets: a new read-only query returns the last N completed minutes per kind, correctly crossing midnight. Bars auto-range to the window maximum with a sensible floor (per-channel calibration knobs stay deferred, per the concept's own v1 cuts).
- Peak-hold is the session's maximum observed rate per channel. It resets on relaunch in v1.
- Missing sources keep the concept's honest language: a source-missing COGNITION channel reads UNCALIBRATED — NO LOCAL SRC; a permission-gated MECHANICS channel reads UNCALIBRATED — PERMISSION with the existing grant affordance. The lattice still lights for whatever does report.
- The paper receipt strip rendering inside the dark panel is intentional contrast and does not change.
- The `DaySheet` core stays: the General Ledger window still uses it for unposted-day detail.
- Deferred: the menubar label as a mini-meter (it keeps the running-balance figure), calibration knobs, and the Desktop widgets.

## Visual design: the Byte Flow deck (shipped)

The panel is a chart-led live dashboard on a byte-native dark chassis. The governing rule is that light is data: every glow, pulse, and ticker value is driven by real measurements, and the panel settles to a quiet dark baseline when nothing flows.

- Chassis: panel width 360, fixed, leading-aligned, ALWAYS dark in both appearances. Background #0B0E11; cards #12171C with corner radius 8 and a 1px hairline #1E262D; dial text #E8EDF2 with a dim variant at 55% opacity. System monospaced font with tabular digits throughout.
- Channel signal colors (each channel owns exactly one): TRAFFIC teal #46E0C8, STORAGE violet #9B8CFF, COGNITION amber #E8A317, EXPOSURE green #5FC46A, MECHANICS coral #FF6B5B. Brass gold appears nowhere on the deck; it stays reserved for BALANCED on ledger surfaces.
- Header: "BYTELIFE // FLOW" in tiny dim caps with a LIVE chip that lights amber only while some channel clears its liveness threshold; the hero figure (today's posted byte volume) at 26pt semibold monospaced with a soft amber glow and the numeric-roll transition; a combined traffic-plus-storage flow line in teal, dimmed when the byte channels are idle; and the hex ticker, a thin teal line printing the last four real inter-poll byte deltas as hexadecimal, newest first.
- The hero flow chart (Swift Charts, a system framework, so the zero-dependency rule holds): the last 30 completed minutes as two smooth gradient area-plus-line series, network in teal and disk in violet, on ONE shared absolute bytes/s scale so the taller series really is the bigger flow, with a floor on the domain so an idle half hour reads flat instead of zooming into noise.
- Channel cards in order TRAFFIC, STORAGE, COGNITION, EXPOSURE, MECHANICS. Rate cards carry: the channel name in its color, a small pulsing live dot (inserted only while the channel is live, so a quiet panel is still), the live readout glowing in the channel color when live and dim otherwise, a gradient area sparkline of the 30-minute window in the channel color with the window maximum held as a dial-white dot, and a dim sub-line with today's directional totals plus the session peak readout. COGNITION additionally shows the ratio bar: a slim two-segment bar of today's prompted (dim) versus generated (bright) tokens — the exchange rate as a shape.
- EXPOSURE is the one radial element, because attention is the one absolute-scale channel: a green ring showing the fraction of the day attentive, the accumulated duration as its readout, and its sparkline scale normalized against a true 60-second full scale in the core.
- Liveness is a real gate, not a nonzero test: each channel has a threshold (512 B/s for the byte channels, 1 tok/min, 1 kpm) and the core snaps the EMA to exactly zero once it decays well below threshold, so live lights actually turn off. On panel reopen the rates cold-start (previous snapshot and smoothing dropped, peaks kept) so no phantom decaying rate ever shows and a close-gap average can never forge a session peak.
- UNCALIBRATED channels keep the honest language ("UNCALIBRATED — NO LOCAL SRC" for a missing AI source; "UNCALIBRATED" with the calibrate affordance for permission-gated MECHANICS) in the channel color at 70%, over a flat chart.
- Motion rules, exhaustive: numeric rolls on readouts, the per-channel live dot's breath gated on liveness, nothing else animates.
- The footer keeps Reconcile, the POSTED stamp logic and colors, View receipt, launch-at-login, the General Ledger button, and Quit on the dark chassis. No spanning or long content may drive the panel wider than its frame; long tags wrap or truncate.

---

# Iteration 5: adaptive appearance, the modern ledger window, and the shareable receipt

Status: executed 2026-07-07 (see CHANGELOG.md, iteration 5). Approved the same day from founder feedback on 0.3.0: the deck looks good but must adapt to light and dark appearance; the General Ledger window should match the panel's modern style instead of the paper-ledger look; the receipt stays (it is fun) but should look like a real thermal receipt and export as a PDF or image for social sharing. Post-execution notes: the review pass confirmed zero findings; of its minors, the light-mode receipt gained a faint edge stroke and a failed save now surfaces an alert instead of silently discarding the write. The multi-device and agentless-SSH design in docs/design/multi-device.md remains the next structural layer.

## Decisions

- Appearance-adaptive deck. LatticePalette becomes scheme-aware: every role (chassis, card, hairline, dial, dim, five channel signal colors) resolves against the current color scheme. Dark keeps the shipped values exactly. Light variants, pinned: chassis #F2F5F7, card #FFFFFF, hairline #DDE4EA, dial #1A2129 (dim 55%), TRAFFIC teal #0E9C86, STORAGE violet #6B5AE0, COGNITION amber #B87E0A, EXPOSURE green #3D9C4C, MECHANICS coral #E0503E. Glow shadows soften on light (about half the dark opacity) so they read as warmth, not blur. The LIVE chip keeps an amber fill in both schemes with legible text. The panel and the General Ledger window both track the system appearance; nothing is hard-coded dark anymore.
- The General Ledger window adopts the deck's modern language on the adaptive chassis: card surfaces with hairline strokes, monospaced tabular figures, channel/stamp colors as chips. Layout stays three-plus-one rails (accounts, periods, day detail, trial balance) but restyled, and the periods column gains a small history bar chart at its top: posted byte volume per recorded day (Swift Charts, teal bars, newest right), so the window opens on a shape of the past, not just a list. The per-day posted-volume series computes in ByteLifeCore (from the existing multi-day totals query) and is tested.
- The receipt becomes a real thermal artifact. The stored receipt_text remains the immutable audit source rendered verbatim; the chrome around it changes: torn zigzag edges top and bottom (a real tear, not a dashed rule), receipt paper stays paper-colored in BOTH appearances (a receipt is paper; it should look slightly lifted with a soft shadow on the dark deck and on light), and the footer gains a barcode drawn deterministically from the 16-hex content hash (each hex digit maps to a fixed bar-width pattern; the hash prints beneath it). The barcode derivation lives in ByteLifeCore and is tested; the same receipt always draws the same barcode.
- Receipt export and sharing. The receipt view renders to a shareable artifact via ImageRenderer at 2x: a Share button opens the system share sheet with the PNG (the social-media path), and Save… writes PNG or PDF through a save panel (PDF drawn vector-side via a CGContext PDF pass, not a rasterized page). Both receipt surfaces (the panel strip and the General Ledger day detail) get the same compact toolbar. Exported artifacts contain exactly the stored receipt including the hash and barcode, so a shared receipt stays tamper-evident.
- Version bumps to 0.4.0.

## Verification

`swift build` and `swift test` green with the new core logic (per-day posted-volume series, barcode pattern derivation) tested; the packaged app renders the deck and the window correctly in both appearances (flip System Settings appearance to check), and a receipt exports to PNG and PDF files that open cleanly.

## Verification

`swift build` and `swift test` green with the new core (rate math, normalization, peak-hold, minute-window query across midnight) under test; the packaged app relaunches and renders the Meter Bridge with live rates while the Ledger surfaces behave unchanged.

## Verification

`swift build`, `swift build -c release`, and `swift test` green; the packaged app relaunches against the existing live store, migrates it to v2, renders the Ledger panel, and can close today's books producing a stored, hash-stamped receipt.
