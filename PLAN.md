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
