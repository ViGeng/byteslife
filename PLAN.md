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

## Verification

`swift build`, `swift build -c release`, and `swift test` green; the packaged app relaunches against the existing live store, migrates it to v2, renders the Ledger panel, and can close today's books producing a stored, hash-stamped receipt.

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

## Verification

`swift build` and `swift test` green with the new core (rate math, normalization, peak-hold, minute-window query across midnight) under test; the packaged app relaunches and renders the Meter Bridge with live rates while the Ledger surfaces behave unchanged.

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

---

# Iteration 6: working share, and the Back Office redesign

Status: executed 2026-07-07 (see CHANGELOG.md, iteration 6). Approved the same day from founder feedback on 0.4.0: the receipt Share button activates a target (Messages) but nothing attaches or sends; the General Ledger window as a whole is not good and needs a genuine redesign with much better UIs and layouts; the receipt paper itself is right and stays untouched. Post-execution notes: the review confirmed zero findings; from its minors, the share picker is now retained until its delegate reports close (show() is non-blocking, so a local could deallocate under the open menu), a share that cannot anchor alerts instead of silently no-opping, and the window loads once per open instead of twice. The share path still needs the founder's manual click to confirm end to end, since the share sheet cannot be exercised headless.

## Share fix (root cause known)

ReceiptShareItem defers the PNG render into the Transferable DataRepresentation closure. The share service pulls the data after the MenuBarExtra panel has closed and the SwiftUI transfer context is torn down, so the target app activates with no payload. Fix: render EAGERLY on the main actor when Share is clicked, write the PNG to a uniquely named file in the temporary directory, and present an `NSSharingServicePicker` with that file URL, anchored to a real NSView via an NSViewRepresentable coordinator (`show(relativeTo:of:preferredEdge:)`). File URLs are the reliable payload for Messages and Mail. The ShareLink/Transferable path is removed. Save flows keep NSSavePanel. Both receipt surfaces use the same control.

## The Back Office: General Ledger window redesign (binding)

The window becomes a two-pane day dashboard instead of four text rails. The accounts rail is removed (it only highlighted), and the sidebar history chart card is removed (posted byte volume is near-zero for the AI-backfill days, so it rendered as one lonely bar). All chrome uses the adaptive LatticePalette; accounting figures keep debit/credit semantics with scheme-aware variants added to the palette (light keeps oxblood #9B3B2F and ledger-green #3B6B4A; dark uses legible variants #E07A66 and #66C08A). Stamp colors stay: brass only BALANCED, oxblood FLAGGED, dial/ink arrears.

- Sidebar (~280pt), PERIODS: a scrollable list, newest first. Each row: date ("Jul 7" plus a dim weekday), a stamp chip (OPEN in hairline style when unposted), and two thin activity minis under the date — an amber bar for the day's tokens and a teal bar for the day's bytes, each normalized across all listed days — so the list itself is the history chart. Selection gets a card background and a 2pt accent edge. Pinned at the sidebar bottom: a compact ALL TIME card, five rows (account, debit, credit in the scheme-aware figure colors), replacing the old trial-balance rail. Distance Hauled renders on one line.
- Main pane, the day dashboard. Header: the full date ("Tuesday, July 7, 2026") with the stamp chip beside it; right-aligned, the day's posted byte volume as a hero figure with a dim label; the primary action beside it — "Close the books" for an unposted day, or the Share/Save receipt toolbar plus a "View receipt" toggle for a posted one.
- Hero day chart: the selected day's 24 hours as the deck's flow chart (traffic teal and storage violet areas on one shared scale, hour axis marks at 0/6/12/18/24 in dim text), on a card, ~90pt tall.
- Account cards below, in a grid: the Token Account card spans full width (Payable/Receivable with figure colors, exchange rate, cache memo, and 24 hourly amber bars), then a 2x2 grid of Traffic (teal), Storage (violet), Hours Under the Lamp (green, attentive minutes per hour bars, percent of day), and Labor (coral, keys plus distance). Every card: channel-colored title, the day total right-aligned, 24 hourly mini bars in the channel color, and the account's figures in compact rows. Hourly data comes from a new indexed single-day store query aggregating minute buckets into 24 hour buckets, shaped by a pure, tested core model (DayStory), alongside a tested DayActivity series for the sidebar minis.
- For a posted day, the receipt strip renders below the account grid (paper on chassis, existing component) with the same toolbar. Days with no data show an honest empty state. Selection, exactly-once posting, arrears semantics, and the day-posted notification reload keep their behavior.
- Window minimum size ~1000x640; version bumps to 0.5.0.

## Verification

`swift build` and `swift test` green with the new store query and core models tested; the packaged app's Share button actually attaches the PNG in Messages (manual check by the founder); the redesigned window reads as a dashboard in both appearances.

---

# Iteration 7: instant panel, LIVE control, Messages-proof sharing, period granularity, and the brew tap

Status: executed 2026-07-07 (see CHANGELOG.md, iteration 7). Post-execution notes: the review confirmed one major that the adversarial pass proved with a probe — the 10-second peak gate leaked, because a long-gap average carried in the display EMA and the next short tick promoted its residue to a peak; peaks now come from a separate peak-only EMA that integrates exclusively short-gap measurements and resets when the chain breaks (regression-tested end to end, including recovery). Two minors were also fixed: the aggregate hero chart plots chronologically by index instead of by day-of-month (cross-month weeks no longer scramble), and switching between aggregate granularities carries over the period being viewed instead of a stale day selection. The tap is live: releases publish to the public homebrew-tap repo (the byteslife source stays private), scripts/release.sh owns the whole flow, and the cask was verified by tap + parse + fetch with checksum. Approved 2026-07-07 from founder feedback on 0.5.0. Five asks: a Homebrew tap so others can install the app; the panel visibly "slides into frame" on first open; sharing to Photos works but Messages still attaches nothing; periods should offer more granularity than day-by-day (this week, last week, last month); and the LIVE state appears with a delay after opening — it should show directly, LIVE should be a toggle button, and nothing should refresh in the background beyond a slow periodic tick.

## Decisions

- Instant panel, no transition. Two causes, two fixes. First, the visible slide is the animated first refresh after open (the panel renders stale, then animates to fresh); the first refresh after panelDidAppear now applies WITHOUT animation, so the panel appears fully formed, and only subsequent ticks roll. Second, the delayed LIVE chip is the reopen cold-start; the honest fix is warm background state: the slow background tick (30 s, unchanged cadence) now also carries the snapshot and EMA forward cheaply (totals only, no minuteSeries fetch), and the reopen reset applies only when the last snapshot is older than 45 seconds. Honesty is preserved by a new core rule: the session peak only updates when the elapsed inter-snapshot gap is at most 10 seconds, so a background or gap average can never forge a peak (tested).
- LIVE becomes a control. The chip is now a button toggling live mode, persisted via AppStorage (default on). Live mode on: the open panel ticks every 2 s as today. Live mode off: opening the panel performs exactly one refresh (data as of the click) and no per-tick updates while open; the chip renders as a dim outlined OFF state and the pulse dots and glow gating go quiet. Panel closed: both modes keep only the slow 30 s background tick that freshens the menubar label and carries the snapshot. Nothing else runs in the background.
- Messages-proof sharing. Photos (a UI-less service) works; compose-style targets like Messages attach their compose session to the host window, and the menubar panel dies the moment the target activates, killing the session. Sharing therefore always happens from a stable window: clicking Share opens a compact Receipt window (a real titled window showing the receipt strip on the chassis with Share/Save buttons) and immediately presents the sharing picker anchored inside it after the window is front and key (one runloop turn later, so anchoring is valid). The window stays open behind the compose session and closes with its close button. Both surfaces (panel and Back Office) route Share through this window; Save stays inline everywhere (NSSavePanel blocks and is unaffected).
- Period granularity. The Back Office sidebar gains a segmented granularity picker: Day, Week, Month. Weeks are ISO-8601 (Monday start) labeled like "Week 28 · Jul 6–12"; months are local-calendar labeled "July 2026". Grouping happens in a tested core model (PeriodGrouping) over the recorded day epochs; aggregate rows show the same amber/teal activity minis summed over the period. Selecting a week or month shows an aggregate story: the hero chart becomes per-day traffic/storage bars across the period (one bar pair per day) instead of hourly areas, account cards aggregate totals with per-day mini bars, and the receipt section is replaced by a posted-coverage line ("3 of 7 days posted") with the period's day stamps as chips — clicking a chip jumps to that day in Day granularity. Receipts remain day-scoped artifacts; aggregate periods never compose receipts (the weekly Statement remains future work and is unaffected by this view-level aggregation).
- Homebrew tap (done by the orchestrator after the build lands, since it publishes public artifacts): a scripts/release.sh that builds the release app bundle, zips it, computes the sha256, and creates a GitHub release with the zip; a new public tap repo (ViGeng/homebrew-tap) carrying Casks/bytelife.rb pointing at the release asset, so installation is `brew tap vigeng/tap` then `brew install --cask bytelife`. The app is ad-hoc signed and not notarized, so the cask carries an honest caveat that first launch needs right-click-Open (or the user installs with --no-quarantine). Version bumps to 0.6.0.

## Verification

`swift build` and `swift test` green with the new core rules (peak gap-gating, warm reopen, period grouping) tested; the founder confirms: no slide-in on first open, LIVE lit immediately when traffic flows, the LIVE toggle behaves, sharing a receipt reaches Messages with the image attached, and `brew install --cask` works from a clean tap.

---

# Iteration 8: the frozen-input fix, adjustable windows, and the wider estate

Status: executed 2026-07-07 (see CHANGELOG.md, iteration 8). Post-execution notes: the review confirmed three majors, all fixed — the stale-tap detector now counts mouse travel as proof of a live tap (mouse-only attentive use no longer false-flags), persistent file watchers are bounded to recently-modified session files with a cheap stat re-check for older ones (1,327 historical Codex files against a 256-descriptor launchd limit would otherwise exhaust fds and starve nettop and SQLite), and TypingCadence is wired into the Back Office Labor card as peak/average memo rows. Two data minors were also fixed (a Gemini per-file high-water mark closes a double-count hole past the 45-day dedup prune; the auxiliary chips distinguish an off sensor from a running-but-idle one). Empirical facts baked into the parsers: Codex token_count events with null info are rate-limit heartbeats; Gemini token data lives in tmp/<hash>/chats/session-*.json, not logs.json. The auxiliary collectors live in a separate registry so a batteryless machine can never permanently FLAG receipts. The "N of M sources" disclosure is panel-scoped by design. Approved 2026-07-07 from founder feedback on 0.6.0 and the metrics questionnaire. Three threads: MECHANICS numbers never change (a real bug); the panel's chart window should be adjustable per channel (30 minutes up to day-wise); and the founder selected every proposed metric — more AI sources (Codex CLI and Gemini CLI), an energy account, an app-focus ledger, files touched, clicks and scrolls, typing cadence, sessions and unlocks, and distinct hosts contacted.

## The frozen-input diagnosis (bug first)

Input Monitoring TCC grants bind to the code-signing identity. The app is re-signed ad hoc on every package run, so each rebuild is a new identity: the old grant goes stale and the event tap is created successfully but silently delivers nothing — the "silent disable race" the feasibility research documented. Counts froze exactly this way (collected once, never moved again). Fixes, all three:

- Detection: a tested core state machine flags a suspect tap — tap reportedly running but zero input events accumulated across a window where EXPOSURE was attentive (3 or more attentive minutes). The MECHANICS channel then drops to needsPermission with the honest tag "RE-GRANT — SIGNATURE CHANGED" and the calibrate affordance deep-links to Input Monitoring settings (the user removes and re-adds the app).
- Prevention: package-app.sh signs with the identity named "ByteLife Local" when one exists in the keychain (a one-time self-signed code-signing certificate the founder creates in Keychain Access), falling back to ad hoc. A stable identity keeps grants valid across rebuilds.
- Recovery guidance in the app: the re-grant tag plus the settings deep link.

## Adjustable chart windows

Each rate channel card and the hero flow chart get a window selector: 30M (30 one-minute buckets), 1H (30 two-minute), 6H (36 ten-minute), 24H (48 thirty-minute). Selection is per channel, persisted via AppStorage, rendered as a small dim monospaced menu beside the channel title. The core gains a window spec (total minutes, bucket minutes): minuteSeries data aggregates into buckets, values convert to the channel's rate axis per bucket (so floors and peak positions stay on one scale), and EXPOSURE keeps its absolute per-minute scale semantics within larger buckets (attentive seconds per bucket over bucket capacity). Tested: bucket aggregation, rate-axis conversion, floors across window sizes.

## More AI sources: Codex and Gemini

Two new AIUsageSource adapters behind the existing protocol, both local-log parsers with the existing dedup ledger and atomic ingest:
- CodexSource: ~/.codex/sessions/**/rollout-*.jsonl, token_count events carrying CUMULATIVE totals — per-event deltas come from subtracting successive snapshots per session (the research-verified semantics); dedup keys from session + event position.
- GeminiSource: the Gemini CLI's local session logs (inspect a real ~/.gemini on this machine if present; otherwise implement against the ccusage-documented format) with the same discipline.
Both get hand-authored fixtures and tests (normal, duplicate, rotation, malformed). The Token Account disclosure becomes source-aware: "Partial: N of M sources reporting", listing which are open.

## New accounts and sensors

All additive; the samples schema takes new kinds without migration, plus schema v3 adds two tables:
- Energy: an EnergyCollector reading IOKit power-source data (adapter wattage or battery discharge) into kind energyMilliwattHours as additive deltas. Book as watt-hours.
- App focus: an AppFocusCollector polling NSWorkspace.frontmostApplication (5 s cadence, no permissions) into a new focus(day_epoch, bundle_id, seconds) table with UPSERT accumulate (per-app needs its own dimension; the samples table stays single-dimensional). Day story shows the top apps.
- Files touched: an FSEvents-based collector counting file create/modify events under the home directory (count only, never paths), with default exclusions (~/Library, caches, .git internals, node_modules, .build) into kind filesTouched.
- Distinct hosts: a nettop-polling collector (the researched fallback path; undocumented format, availability degrades honestly if parsing fails) recording SALTED HASHES of remote hosts into a hosts_seen(day_epoch, host_hash) dedup table — the metric is the distinct count; no hostname is ever stored.
- Clicks and scrolls: the existing event tap adds mouse-down and scroll-wheel events (same permission, count only) into kinds inputClicks and inputScrollUnits.
- Sessions and unlocks: ScreenCollector counts screen unlocks (kind screenUnlocks) and attention sessions (kind attentionSessions, incremented on each attentive-state entry).
- Typing cadence: pure derivation from existing keystroke minute buckets (peak and average keys per active minute); no new collection.

## Surfaces

The panel keeps its five flagship channels and gains a compact ALSO ON THE BOOKS strip above the reconcile bar: small adaptive chips for energy (Wh), top app (name + minutes), files touched, distinct hosts, and unlocks — figures only, no charts, honest dashes when a sensor is off. MECHANICS' sub-line gains clicks and cadence. The Back Office day story gains cards or memo rows for the new accounts (Energy Account, Focus Account with top five apps, Files Touched, Hosts Contacted, sessions/unlocks as EXPOSURE memos). The receipt gains an AUXILIARY section booking the new counters in the same dry grammar (golden fixture regenerated; the hash rule is unchanged — new receipts simply carry more lines). Version bumps to 0.7.0 and ships to the tap via release.sh.

## Verification

`swift build` and `swift test` green with the new core (window buckets, stale-tap detector, Codex/Gemini parsers, focus and hosts stores, cadence) tested; the founder re-grants Input Monitoring once and MECHANICS moves again; window menus switch charts between 30M and 24H; the new chips read real values.

---

# Iteration 9: true energy, the sensor deck, fine-grained AI, and working windows

Status: executed 2026-07-07 (see CHANGELOG.md, iteration 9), version 0.8.0 shipped to the tap. Post-execution notes: the SMC user client requires an exact 80-byte C struct layout that Swift's packing silently broke until padded (discovered by hardware verification, PSTR read 9.8 to 11.1 W on AC); the ambient-light gauge is captioned as a unitless level because the sensor reports raw uncalibrated counts, not lux; Bluetooth shipped counts-only with no names or hashes (amended in the decisions below); thermal-state changes, charging sessions, and the battery cycle count live as day-scoped meta counters rather than new kinds; ambient light, brightness, and the lid angle read sourceMissing on this machine, which is the designed degradation. Originally approved 2026-07-07 from founder feedback on 0.7.0 and the sensor questionnaire (everything selected). Threads: the Grant Permission button did nothing (macOS prompts once per identity; the orchestrator reset TCC state manually — the app must own this recovery); the macOS 26 Settings path in the permission hint is wrong; energy read zero on AC power (it measured battery discharge only); a user-tweakable custom window; per-model and per-session AI stats; a terminal commands counter; and the full sensor slate — lid open/close (founder-requested), thermals and fans, battery health and charging, ambient light, display brightness, wakes and boots, audio device switches, Bluetooth peripherals, volume changes. Face-to-screen working distance is noted as future work only (camera/TrueDepth ranging; needs its own privacy design).

## Decisions

- Permission recovery lives in the app. The grant affordance becomes a small flow: request; if no prompt appears (preflight still false immediately after a request that returned), offer "Reset permission state…" which runs `tccutil reset ListenEvent com.vigeng.bytelife` via Process (per-user, no privileges) and requests again — the prompt then genuinely fires. The settings hint drops the stale pane path: on macOS 26 the reliable instruction is the System Settings search field ("Input Monitoring"); the deep link stays as a best-effort with a plain open-System-Settings fallback.
- True energy: an SMC reader (AppleSMC user client, the technique the open-source Stats app uses, no privileges) sampling system total power (key PSTR, watts as float), integrated over elapsed time into the existing energyMilliwattHours deltas. The battery Amperage x Voltage path stays as the fallback when SMC is unavailable. The same SMC client serves the thermal keys below. Injectable readers, tested integration math.
- Working window: alongside 30M/1H/6H/24H, a user-defined WORK window — one duration (1 to 48 hours) configured once from any window menu ("Custom…", a small stepper popover), stored globally, then selectable per channel like the fixed options. Bucket size derives to keep 30 to 48 buckets.
- Fine-grained AI: schema v4 adds ai_models(day_epoch, source, model, input, output, cache_creation, cache_read, PRIMARY KEY(day_epoch, source, model)) and ai_sessions(session_id PRIMARY KEY, source, first_seen, last_seen, day_epoch). Parsers already see model, session id, and timestamps: AIUsageEvent gains source/model/session fields and the atomic ingest extends to upsert model rows and session first/last timestamps in the SAME transaction. Surfaces: the Back Office COGNITION card gains a BY MODEL breakdown (top models with token bars) and session memos (sessions today, average and longest length); the panel stays light.
- Terminal commands: a ShellHistoryCollector tailing ~/.zsh_history and ~/.bash_history via the existing FileTailer offsets, counting appended entries ONLY (never storing command text; zsh extended-history entries counted by their ": ts:dur;" headers, plain histories by line). Caveat accepted: shells configured to write at exit book in bursts. Kind commandsRun; surfaced as a Labor card memo and an ALSO ON THE BOOKS chip.
- The sensor deck. Additive counter kinds: lidOpens, systemWakes, systemBoots, audioDeviceSwitches, btConnects, volumeChanges. Sampled curves get schema v4's third table gauges(day_epoch, minute, gauge TEXT, value INTEGER, PRIMARY KEY(day_epoch, minute, gauge)) storing per-minute readings: cpuTemperature (deci-degrees), fanRPM, batteryCharge (percent), ambientLux, displayBrightness (per mille), systemPowerWatts (deci-watts). Sensors: lid via IOPMrootDomain clamshell state notifications (angle best-effort via the HID lid-angle sensor where present, booked as a gauge lidAngle when readable); thermals/fans via the shared SMC client plus ProcessInfo.thermalState change counts; battery health/charging via AppleSmartBattery (charge curve, charging-session counts, cycle count as a day story memo); ambient light via IOKit HID (best-effort, sourceMissing when absent); display brightness via DisplayServices (best-effort); wakes/boots from existing notifications plus boot time; audio switches and volume via CoreAudio; Bluetooth connects via IOBluetooth. (Amended post-execution: the shipped Bluetooth collector counts connected-peripheral rises only and stores no name or hash at all, strictly more private than the salted-hash design first written here; a distinct-peripheral figure can adopt the hash journal later if wanted.) EVERY sensor degrades to sourceMissing honestly; none touches contents or identifiers.
- Surfaces: the Back Office day story gains a SENSORS section — small curve charts (temperature, charge, lux, brightness, power) in a muted palette plus count memos (lid opens, wakes, audio switches, BT connects, volume changes) — and the receipt AUXILIARY section adds commands run, lid opens, and wakes (curves never print on receipts). The panel adds only the commands chip. All new collectors join the auxiliary registry (never the flagship stamp snapshot).
- Version 0.8.0, shipped to the tap.

## Verification

`swift build` and `swift test` green (v4 migration proven against a populated v3 store; SMC/sensor readers injectable and their math tested; AI model/session ingest atomic and tested; history counting tested against fixture histories). The founder sees real watt-hours on AC power, the WORK window appears in every menu once set, the COGNITION card breaks down by model, and Grant Permission recovers by itself.

---

# The queue, reorganized (2026-07-07)

Founder direction: improve efficiency and token-efficiency, and re-order the backlog more reasonably. Three rules now shape the queue. First, an iteration stays inside one subsystem cluster, so a build touches a coherent file set instead of re-reading the whole tree. Second, an iteration carries at most one schema migration. Third, verification effort scales with risk: money math and privacy-sensitive parsing earn adversarial review, while mechanical UI rides on the test suite plus one focused review pass. Orchestration follows the same discipline — small builder crews on disjoint file sets, resume instead of rerun on failures, and the strongest reviewers reserved for the riskiest pieces.

Founder halt, evening of 2026-07-07: feature iterations paused after 0.8.0 crashed repeatedly under real use. Stability comes first; the stabilization entry below records the findings. Iterations 10 to 12 stay designed and queued, resuming only on the founder's word.

The order, each step gated on the previous ship:

1. Iteration 9 (shipped 2026-07-07, 0.8.0): sensors, true energy, permission self-recovery, fine-grained AI (schema v4), the WORK window, shell commands.
1a. Stabilization (0.8.1, executed the same evening): the Bluetooth TCC kill, the beachballing permission flow, and the blocking launch — see "Stabilization" below. On 2026-07-08 the repo went public, the Homebrew tap moved to the conventional layout (releases on byteslife itself, the cask points there, the old private-repo hosting hack retired), and 0.8.1 shipped to the tap with a public-facing README.
2. Iteration 10 (executed 2026-07-10, 0.9.0; the tap publish waits on the founder's verdict): the realtime token meter, the notional AI cost, and the Composite. All three only read what v4 already records, so this was the highest founder-visible value per line changed.
2a. Iteration 10a (executed 2026-07-10, 0.9.1): the self-keeping books — the founder dropped the Reconcile ritual; days auto-close at midnight with a stamp-honesty grace window, historical days backfill in arrears, the open day renders a provisional unsealed receipt, and receipts gain Print. Founder feedback on the panel the same day also retired the hero flow chart (the TRAFFIC and STORAGE cards carry their own sparklines, and better overall metrics are planned), shipped in the same 0.9.1 release.
3. Iteration 11 (0.10.0, the deeper record, schema v5): the Workshop (git) and the Journal in one migration, plus the working-hours strip as the first journal-powered insight.
4. Iteration 12 (0.11.0, beyond the machine, schema v6): the Engagement Book (calendar) before the Correspondence account (email), ordered by permission friction.
5. The standing backlog behind those: the weekly Statement, multi-device holdings and agentless SSH collection, the app rename, and face-distance sensing as noted future work.

---

# Stabilization (2026-07-07 evening): the Bluetooth kill and the frozen main thread

Status: executed 2026-07-07, version 0.8.1. Founder report on 0.8.0: frequent crashes while clicking around, and the Grant Permission button responded slowly before the app died. Diagnosed from the five crash reports in DiagnosticReports, all carrying one signature.

## Findings and fixes

- THE CRASH (all five reports): a TCC privacy kill. Iteration 9's BluetoothCollector called `IOBluetoothDevice.pairedDevices()` on its 30-second tick, Bluetooth enumeration is TCC-protected, and the packaged Info.plist carried no `NSBluetoothAlwaysUsageDescription`, which macOS punishes with SIGABRT. The app could not survive a minute. Two-layer fix: the usage description is now in the packaged Info.plist, and the collector gates every tick on `CBCentralManager.authorization == .allowedAlways` (a read-only, non-prompting check) so an unauthorized process can never reach IOBluetooth, plist or no plist. Unauthorized ticks book `.needsPermission` honestly. The app still never raises the Bluetooth prompt on its own, so the family stays dormant until a future iteration adds an explicit enable affordance; that affordance is now queued work.
- THE BEACHBALL: the panel's Grant Permission and Reset-permission-state actions ran a blocking XPC round trip (`CGRequestListenEventAccess`) and a synchronous `Process` (`tccutil`) + a second blocking request on the main actor. Both flows now run detached off the main actor and only publish their outcome back on it; the reset button awaits its exit code asynchronously.
- THE SLOW LAUNCH: both collector registries started synchronously inside the coordinator's init on the main thread, and the AI sources stat every recent transcript (and on first run, tail them all) during discovery. Start-up now runs on a background queue; an audit confirmed no collector needs a main run loop (the event tap spins its own dedicated CFRunLoop thread, FSEvents and CoreAudio use dispatch queues, IOKit sensors poll their own serial queues).
- Sweep results: no other TCC-protected framework is touched anywhere in Sources, and the only other `Process` user (nettop in HostsSeenCollector) already ran on its own queue.

## Verification

`swift build` and `swift test` green (386 tests, including the new fail-closed gate regression: an unauthorized tick must never reach the reader); a soak run confirms the packaged app outlives the old 30-to-60-second crash window with no new crash reports; one adversarial review of the diff.

---

# Iteration 10 (queued behind 9): honest numbers

Status: executed 2026-07-10 (see CHANGELOG.md, iteration 10). Approved 2026-07-07 from founder feedback; scope re-cut 2026-07-07 for efficiency (the Workshop and the Journal moved to iteration 11, email and calendar to iteration 12). Discoveries recorded after execution: Codex and Gemini record cached tokens INSIDE their input channel (verified against real transcripts on this machine, where total = input + output), so AIModelTotal now knows the cache-inclusive sources and every reader prices and displays the uncached input; neither OpenAI nor Google publishes a separate cache-write price, and those sources book no cache-creation channel at all, so that rate equals the input rate and prices a channel that is zero in practice; the composite margin-note rule fires at a factor of two off the median (index at or beyond 200, at or below 50) and outranks the variance rule; a storage error during a close now aborts the close rather than booking a permanent zero-dollar line into the immutable receipt; and the panel refreshes its 28-day baseline on every panel open, because AI backfill lands on past days and the baseline is not rollover-stable. One accepted deferral: the live tok/min readout and the Composite tokens component still include Codex and Gemini cache re-reads, because minute samples carry no per-source dimension; rebooking that channel is an accounting call that iteration 11's AI journal makes cleanly fixable. Three asks, no schema change — everything here reads data that v4 already records. First, make the COGNITION live rate read truthfully while tokens are burning. Second, price AI token usage at official API prices and show the equivalent dollar cost. Third, replace naive summation as the overall figure, because tokens are not bytes and the non-byte accounts cannot honestly add into one number.

## The notional cost at list prices

Most of the founder's AI usage bills through subscriptions, so the honest framing is a valuation rather than a bill: what today's tokens WOULD cost at the official pay-as-you-go API prices. The app stays networkless. Prices ship as a bundled PriceCard in ByteLifeCore with an explicit as-of date (2026-07-07), refreshed at release time by the maintainer, and every cost surface carries the "at list prices, as of" framing. Verified list prices in USD per million tokens, written as input / output / cache read / cache write:

- Anthropic (cache write is the 5-minute tier at 1.25x input; cache read is 0.1x input): claude-fable-5 is 10 / 50 / 1.00 / 12.50. claude-opus-4-8, -4-7, and -4-6 are 5 / 25 / 0.50 / 6.25. claude-sonnet-4-6 is 3 / 15 / 0.30 / 3.75. claude-haiku-4-5 is 1 / 5 / 0.10 / 1.25.
- OpenAI (cached input is 10 percent of input; there is no separate write price): gpt-5.3-codex and gpt-5.2-codex are 1.75 / 14.00 / 0.175. gpt-5.4 is 2.50 / 15.00 / 0.25. gpt-5.4-mini is 0.75 / 4.50 / 0.075.
- Google: gemini-3-pro-preview is 2.00 / 12.00 / 0.20 at the sub-200k-context tier; the long-context uplift is deliberately ignored in v1 and disclosed. gemini-3-flash-preview is 0.50 / 3.00 / 0.05.

Matching is normalized longest-prefix on the stored model string, so dated or suffixed variants price correctly. A model with no match books as UNPRICED: it is excluded from the cost total and the exclusion is disclosed ("2.1K tokens unpriced") instead of being silently zeroed. Cost per (source, model, day) computes from the iteration-9 ai_models rows as input x in + output x out + cache_read x read + cache_creation x write. Surfaces: the Back Office COGNITION card gains a cost line, the BY MODEL breakdown gains a cost column, the receipt Token Account books a "Notional cost (list)" line, and period aggregates sum the daily figures. Tested: the per-model arithmetic, prefix matching, the unpriced fallback, and receipt determinism with a regenerated golden.

## The Composite

Tokens, bytes, seconds, and keystrokes cannot be added, but each can be compared against its own history. The BYTELIFE COMPOSITE is a market-style index over four component series: bytes moved (traffic plus storage), tokens (input plus output), attentive seconds, and input events (keys plus clicks plus scrolls). For each component the baseline is the median of that component over the trailing 28 recorded days. Today's ratio is today over baseline, clamped to [0.05, 20] so a single wild day cannot dominate. The Composite is the geometric mean of the ratios, times 100. It reads like an index: 100 is a typical day, 132 is a third busier than typical, and no unit can outweigh another because the mean is geometric over unit-free ratios. Fewer than 5 recorded baseline days renders an honest "collecting baseline" state instead of a fake number, and a component with a zero baseline drops out of the mean with disclosure. Surfaces: a COMPOSITE chip in the panel header (dim while collecting), the Back Office day header, a line in the receipt totals block ("Composite vs 28-day median: 132"), and a margin-note rule so an exceptional composite can become the day's dry comment. Tested: the median baseline, the geometric mean, clamping, zero-baseline components, and the insufficient-history state.

## The realtime token meter

Founder report: the COGNITION rate reads near zero while tokens are visibly burning. Diagnosis: ingestion is already event-driven (vnode watchers tail the transcripts on write), but AI tools book usage only at message completion, so tokens land in bursts. The 2-second-delta EMA that is correct for network and disk (which genuinely tick every poll) turns a burst into one absurd instantaneous spike followed by a fast decay to zero, so most glances land in a gap and read idle. Fix: COGNITION's live rate becomes a trailing-window rate — the view model keeps a short trail of (timestamp, in+out token total) snapshots in the carried meter state, and the rate is tokens landed over the trailing 90 seconds, expressed in the existing tok/min unit and refreshed every poll. This reads steady while an agentic session is landing messages every few seconds to a minute, decays honestly to zero about 90 seconds after the last landing, changes no collector or store code, and costs nothing (the totals are already fetched every 2 seconds). The session peak becomes the maximum trailing-window rate, which is a sustained figure and needs no separate laundering guard for this channel. Liveness keeps the 1 tok/min threshold against the windowed rate. The hard floor remains source visibility: a single very long turn that writes nothing until it finishes cannot show mid-turn (the transcripts contain nothing to read), which is accepted and undisclosed on the dial. Cache tokens stay excluded from the readout, per the ledger's exchange-rate reasoning. Tested: burst-then-gap reads a steady rate across the gap, decay after the last landing, window trimming, and the peak as a sustained maximum.

## Verification

`swift build` and `swift test` green; the founder sees the COGNITION dial read steady while an agentic session burns, a plausible dollar figure for today's real usage across all three sources, and a Composite near 100 on an ordinary day. Version 0.9.0.

---

# Iteration 10a: the self-keeping books

Status: executed 2026-07-10 (see CHANGELOG.md, iteration 10a). Approved 2026-07-10 from founder feedback on 0.9.0. The founder sometimes pressed "Close the books" accidentally and could not reopen the day, and wanted the receipt printable without any closing act; asked to choose between a confirmation step, a provisional receipt, bookkeeping-style voiding, and dropping the ritual, he chose to drop the ritual entirely. Version 0.9.1, no schema change. Deviations recorded after execution: the grace window guards against the sleep/wake run-loop race with a will-sleep sentinel (awakeSince parks at distant-future at sleep, so a sweep racing the wake notification books arrears rather than live-stamping a midnight the app slept through); the auto-close sweep runs on a serial background queue with a 30-second throttle, never on the main thread, because the one-time upgrade backfill would otherwise repeat the 0.8.1 frozen-launch pattern; the open-day receipt window recomposes on becoming key and on a 30-second timer so a re-raised window never shows hours-old figures; and one reviewer finding was rejected as accepted semantics — a forward clock jump can seal the real today early with partial figures, which is locally indistinguishable from a genuine rollover and whose remedies (clock heuristics or voiding) the founder declined.

## Decisions

- Days close themselves. An auto-closer runs on the existing slow background tick: any recorded day older than the current accounting day that has no reconciliation row is closed automatically. The exactly-once store guard (`INSERT OR IGNORE`) remains the single source of truth, so races between a tick and a launch are harmless.
- Stamp honesty with a grace window. A day closed while the app is awake within a short grace period after its own midnight (10 minutes) stamps BALANCED or FLAGGED from the live collector snapshot, because that snapshot is still an honest witness of the day just ended. Any later close books POSTED IN ARREARS, exactly as manual arrears closes did. On the first run after upgrade this backfill-posts every historical unposted day in arrears, so every recorded day has a receipt.
- The receipt is always available. Past days render their stored, sealed artifact verbatim, unchanged. The open day renders a PROVISIONAL receipt composed live from current figures: it carries a "DAY OPEN — FIGURES AS OF HH:MM" header line where the stamp would sit, and NO content hash and NO barcode, because the hash is the seal of a closed record and an open day has no seal. The provisional variant is compose-only and never stored; the sealed compose path and the stored golden are untouched.
- The buttons change meaning. The panel footer's Reconcile button becomes "View receipt" (opens today's provisional receipt in the receipt window). The Back Office drops "Close the books"; a day's detail always shows its receipt (sealed or provisional) with the existing Share and Save toolbar. Both receipt surfaces gain Print, driven by the existing vector-PDF render through NSPrintOperation.
- Aggregate periods drop the posted-coverage line ("3 of 7 days posted") once every past day is auto-posted; the day-stamp chips stay as navigation.
- Accepted and disclosed semantics: the sealed receipt records the books as known at close time. AI transcripts ingested later can still book tokens onto an already-sealed day (this was true of manual closes too); the day story reads live data and may legitimately show more than the receipt. The margin-note engine and all stamp colors are unchanged; brass stays BALANCED-only.

## Verification

`swift build` and `swift test` green with the auto-closer (rollover close inside and outside the grace window, arrears backfill, exactly-once under repeated ticks) and the provisional compose (no hash, no barcode, header line, sealed path byte-identical) under test; the founder sees yesterday close itself, every historical day carrying a receipt, and today's receipt printable at any moment.

---

# Iteration 11 (queued behind 10): the deeper record

Status: approved 2026-07-07 from founder feedback (git stats, and event-grain records with metadata so insights like working peaks stay derivable). One migration, schema v5, carries both halves. Version 0.10.0.

## The Workshop: git stats

Commits are the most ledger-shaped data on the machine: discrete, timestamped, attributed, and content-hashed. A GitCollector books the day's coding activity from the local repositories, counts only, never contents.

- Discovery: a configurable list of workspace roots (Back Office setting), defaulting to whichever of ~/source, ~/dev, ~/code, ~/Projects, and ~/repos exist. Each root is shallow-scanned (depth 3) for .git directories on start and on a slow rescan timer, with a vnode watcher on each root catching new clones between passes.
- Live tailing follows the AISourceWatch discipline exactly: a repository with HEAD activity in the last 7 days earns one vnode watcher on .git/logs/HEAD (which appends a line on every commit, checkout, merge, and reset, so commits land in the books within milliseconds); dormant repositories get a cheap stat on each rescan pass and no descriptor. This keeps a machine with hundreds of clones under its fd budget.
- Attribution and counting: only commits authored by the user's own git identities count (user.email from the global config plus each repo's local override). Stats come from an incremental `git log --author --since` with --numstat per repository, run through Process against the system git; a machine without git books the family as sourceMissing honestly. Kinds: gitCommits, gitLinesAdded, gitLinesDeleted, gitFilesChanged, gitCheckouts (branch switches from the HEAD reflog). Distinct repositories touched per day derive from the commit journal (see the Journal below) rather than a separate distinct-set table.
- Dedup and honesty: every commit lands as one row in the `git_commits` journal table keyed on its SHA inside the store's atomic ingest, so the same commit seen twice (a re-scan, a repo cloned twice) books once. An amend or rebase mints new SHAs and therefore counts again: ByteLife counts acts of committing, which is the honest reading for an activity ledger, and the plan records that choice. Because commit SHAs are globally stable, the Workshop is the first naturally multi-device-mergeable family: two Macs seeing the same commit will dedup by SHA under the holdings design's event-log union.
- Privacy: repository identity is stored as a salted hash for dedup and distinct counts plus a display basename for the Back Office (the same balance app focus struck with app names). Receipts and every shareable artifact print counts only, never repository names.
- Surfaces: an ALSO ON THE BOOKS chip ("14 commits · +812 −340"), a WORKSHOP card in the Back Office day story (commits, line flows booked debit-and-credit as written against deleted, files changed, checkouts, top repositories by commits), a counts-only line in the receipt AUXILIARY section, and a margin-note rule (a day with more lines deleted than written earns the bookkeeper's approval). The family joins the auxiliary registry, never the flagship stamp snapshot.
- Tested: log parsing against fixture output, SHA dedup across rescans, identity filtering, reflog checkout counting, discovery bounded by depth, and the fd discipline (watchers only on recently active repos).

## The Journal: event-grain records beneath the ledger

Founder direction: keep detailed per-event records with metadata (a commit SHA indexed with its stats, and the other metrics treated the same), so future insights such as working peaks stay derivable without re-collection. In bookkeeping terms ByteLife gains a proper journal, the book of original entry; day cards, receipts, and aggregates are derived views over it, never the only record.

- The continuous families are already journaled. `samples` persists minute-grain counters forever (day_epoch, minute, kind) and iteration 9's `gauges` persists minute-grain sensor levels, so hour-of-day patterns for bytes, keys, attention, and sensors are derivable from what is on disk today. No change needed there.
- The discrete families gain event rows in schema v5. `git_commits(sha TEXT PRIMARY KEY, repo_hash, committed_at, day_epoch, lines_added, lines_deleted, files_changed)` with a day index is both the Workshop's dedup ledger and its journal: one insert per commit, and per-hour, per-repo, and distinct-repo breakdowns are each one query away.
- The AI dedup ledger becomes the AI journal. `ai_seen` gains nullable columns (timestamp, source, model, session_id, input, output, cache_creation, cache_read) populated for every event ingested from v5 onward, written in the same atomic transaction ingest already uses. Rows recorded before v5 keep NULL metadata, so the journal honestly begins at its birthday instead of pretending to reach back; dedup semantics are untouched.
- Retention is forever, matching the ledger's premise. Journal rows are tens of bytes, so a heavy year adds a few megabytes.
- One first insight ships with the schema so the journal earns its keep immediately: the Back Office day story gains a WORKING HOURS strip of three thin 24-hour lanes (keystrokes from minute samples, tokens from minute samples, commits from the journal as dots), each lane naming its own peak hour. There is no cross-family summation; each lane speaks its own unit, per the Composite's reasoning.
- Tested: the v5 migration against a populated v4 store, journal writes inside the atomic ingest, derived distinct-repo counts, and the hour-histogram query across a midnight boundary.

## Verification

`swift build` and `swift test` green (the v5 migration proven against a populated v4 store; the finer assertions live in each section's tested list); the founder sees today's commits on the books minutes after making them, and a working-hours strip naming each lane's peak hour. Version 0.10.0.

---

# Iteration 12 (designed, queued behind 11): the Engagement Book and the Correspondence account

Status: proposed 2026-07-07 from founder ideas (email counts including opt-in words read and written, and calendar events), feasibility-checked, awaiting the iteration-11 ship before build. Calendar leads because its permission is light; email follows behind its Full Disk Access gate. Schema v6 carries both journals. Version 0.11.0.

## The Engagement Book: calendar (the easy half)

EventKit is a clean public API, so this half is low-risk. An EngagementsCollector requests full calendar access (the macOS 14+ `requestFullAccessToEvents` flow, with the usage string in Info.plist) and books per day: events scheduled, hours committed (summed event durations, all-day events excluded from hours and counted separately), meetings (events with more than one attendee), and calendars in use. Refresh on `EKEventStoreChanged` notifications plus a slow poll. Journal grain per iteration 11's principle: one row per event occurrence keyed on a salted hash of the event identifier, storing start, duration in minutes, and attendee count, never a title, location, or attendee name. Denied access books needsPermission honestly; no calendar configured books sourceMissing. The ledger reading is committed time against attended time: the day story can lay hours committed alongside EXPOSURE's attentive hours, two units that stay side by side and are never summed.

## The Correspondence account: email (the harder half)

Feasible for Apple Mail only, and it sits behind Full Disk Access, macOS's heaviest permission, because `~/Library/Mail` is TCC-protected. The design accepts that honestly: the family ships strictly opt-in, reads needsPermission with a plain explanation until the user grants Full Disk Access in System Settings, and the app remains fully functional without it. Third-party clients (Outlook, Gmail in a browser) are invisible to this collector and the disclosure says so.

- Counts (the default tier once enabled): messages received, sent, and drafted per day, plus distinct correspondents as salted hashes through the hosts_seen pattern. Source: Apple Mail's Envelope Index SQLite database under `~/Library/Mail/V*/MailData/`, opened strictly read-only with busy-retry (Mail owns the file), consumed incrementally by ROWID high-water mark, with an FSEvents watcher plus a slow poll driving scans. The Envelope Index is metadata only, which fits the privacy rule structurally: the counts tier never opens a message body.
- Words written and words read (a second, separately toggled tier, off by default, per the founder's "only turned on"): word counts computed in memory from message bodies (.emlx files, MIME/HTML stripped to text) and discarded, storing only integers. Words written counts bodies of newly sent and drafted messages. Words read counts bodies of messages whose read flag flipped since the last scan, disclosed in the UI as an approximation ("words in mail you opened"), because macOS records opening, not reading.
- Privacy line, stated everywhere the family surfaces: no subject, sender, address, or body text is ever stored; correspondent hashes are salted and non-reversible like host hashes; receipts and shareable artifacts print counts only.
- Journal grain: one row per message event keyed on a salted hash of the message identifier, storing direction, timestamp, and nullable word count.
- Surfaces: an ALSO ON THE BOOKS chip ("31 rcvd · 12 sent"), a CORRESPONDENCE card in the day story (received against sent as the debit-credit pair, drafts and correspondents as memos, word flows when the tier is on), a counts-only receipt AUXILIARY line, and honest per-tier availability states.

## Verification

`swift build` and `swift test` green (Envelope Index reader against a fixture database, word counting against fixture .emlx files, EventKit collector behind an injectable store protocol); the founder grants calendar access and sees today's engagements booked, then opts into mail and sees the day's correspondence counts without the app ever persisting a word of content.
