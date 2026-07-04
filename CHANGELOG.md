# Changelog

## 2026-07-04 — Iteration 0: concept and creative direction

The plan for this iteration was to turn the founding idea, a native macOS app that tracks digital life in bytes, into a grounded concept brief before any code is written.

Progress: a 14-agent workflow ran five macOS feasibility researchers (AI tokens, network, disk, screen time, input), one competitive landscape scan, five independent creative directions, and a three-judge panel scoring desirability, conceptual honesty, and buildability. The Ledger direction won (scores 8, 9, 8) and was synthesized with grafts from the other directions into README.md. Raw research was preserved under docs/research/. Next step: the founder picks the creative direction and distribution channel, then iteration 1 plans the v1 architecture.

## 2026-07-04 — Iteration 1: implementation plan and handoff to the dev Mac

The plan for this iteration was to design the full v1 scaffold and hand the project off through GitHub, since development happens on a different Mac.

Progress: decisions were recorded (menubar-first form factor, Developer ID distribution, core-plus-collectors architecture, Swift Package with zero dependencies). An architect agent produced the detailed implementation design, including an empirically verified dedup key for Claude Code token parsing, and it was saved as PLAN.md. The repo was initialized in git and pushed to github.com/ViGeng/byteslife. Next step: execute PLAN.md on the development Mac, starting with the Package.swift skeleton and `swift build`.
