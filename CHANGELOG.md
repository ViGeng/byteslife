# Changelog

## 2026-07-04 — Iteration 0: concept and creative direction

The plan for this iteration was to turn the founding idea, a native macOS app that tracks digital life in bytes, into a grounded concept brief before any code is written.

Progress: a 14-agent workflow ran five macOS feasibility researchers (AI tokens, network, disk, screen time, input), one competitive landscape scan, five independent creative directions, and a three-judge panel scoring desirability, conceptual honesty, and buildability. The Ledger direction won (scores 8, 9, 8) and was synthesized with grafts from the other directions into README.md. Raw research was preserved under docs/research/. Next step: the founder picks the creative direction and distribution channel, then iteration 1 plans the v1 architecture.

## 2026-07-04 — Iteration 1: implementation plan and handoff to the dev Mac

The plan for this iteration was to design the full v1 scaffold and hand the project off through GitHub, since development happens on a different Mac.

Progress: decisions were recorded (menubar-first form factor, Developer ID distribution, core-plus-collectors architecture, Swift Package with zero dependencies). An architect agent produced the detailed implementation design, including an empirically verified dedup key for Claude Code token parsing, and it was saved as PLAN.md. The repo was initialized in git and pushed to github.com/ViGeng/byteslife. Next step: execute PLAN.md on the development Mac, starting with the Package.swift skeleton and `swift build`.

## 2026-07-07 — Iteration 2: v1 scaffold executed, first running demo

The plan for this iteration was to execute PLAN.md top to bottom on the development Mac and produce the first runnable minimum version.

Progress: a six-stage sequential workflow implemented the package skeleton, the model layer, the WAL SQLite SampleStore with UPSERT minute buckets, the CounterAccumulator, the collector framework, the AI chain (Claude Code parser with the verified dedup key, resumable FileTailer, vnode-watcher source), the four system collectors, the MenuBarExtra panel, and scripts/package-app.sh. A five-dimension review with two-vote adversarial verification then confirmed three real defects: a transcript-watcher file-descriptor leak, a non-atomic AI ingest that could silently lose tokens, and an input-tap failure mode that reported running while counting nothing. A fix pass resolved all three plus the highest-value minors, and its own re-verification caught a deadlock the tap fix had introduced, which was then removed. Ground truth on this machine: swift build, swift build -c release, and swift test (81 tests) are all green, and dist/ByteLife.app launches and runs. On first launch the AI collector backfilled 29 days of real token history from local Claude Code transcripts (about 2.1M input, 9.2M output, 986M cache-read, and 37M cache-creation tokens across 5,001 deduplicated events) while the network, disk, and screen collectors recorded live data. Input counting correctly sits in the needs-permission state until Input Monitoring is granted from the panel. Next step: grant Input Monitoring, let the collectors run for a few days to validate the numbers, then start the Ledger skin and the Reconcile ritual on top of the scaffold.
