# Multi-device design: holdings, convergence, and agentless remote sources

Status: design note recorded 2026-07-07 from founder feedback, targeted at the iterations after the Ledger experience. Nothing here is implemented yet; the schema roadmap below says what must land early because it gets more expensive as data accumulates.

## Problem statement

The founder runs several machines and wants one estate. Three constraints shape the design:

1. Different devices produce genuinely different bytes. Mac 1 is a work machine with its own keystrokes, traffic, and disk churn; Mac 2 is a personal machine with its own. Merging their books must add these, because every one of those bytes happened exactly once, on exactly one machine.
2. Some sources are shared. A remote GPU server consumes AI tokens, and both Mac 1 and Mac 2 can see that server. There is only one replica of that activity, so two observers must never sum into a double count.
3. The app must stay self-contained. It gets installed on the Macs and nowhere else. Remote servers and Raspberry Pis are reached over existing SSH access, and nothing may be installed on the remote side.

## Entity model: holdings

A **holding** is any machine whose activity the estate tracks. Each holding has a stable identifier (a generated UUID plus a human name such as "mac1" or "gpu-01"). The local Mac is a holding; every remote server is a holding. Every sample carries an `origin`, the id of the holding the activity belongs to. Local collectors stamp the local holding's id. Remote collection (below) stamps the remote holding's id, regardless of which Mac did the observing. Attribution follows where the activity happened, never who measured it.

In the Ledger's language, each holding keeps its own branch book, and the General Ledger gains a **Consolidation** view: consolidated statements across all holdings, which is exactly what consolidation means in real accounting.

## Convergence rules

The merge semantics are a textbook grow-only counter (G-Counter) with per-holding entries, plus set-union for event-log sources.

**Device-own metrics add.** Keystrokes, mouse travel, screen time, and a machine's own network and disk counters belong to that machine's holding. For a given `(origin, day, minute, kind)` bucket there is exactly one writer in the world: the holding's own collector. Merging books from two Macs is therefore conflict-free — take the newer value per bucket (values within a bucket only grow), and estate totals are the sum over origins. This is the founder's Mac 1 + Mac 2 case: addition is correct because the origins are distinct.

**Shared sources attribute to the source, and split into two cases.**

- *Event-log sources* (AI transcripts, and any future append-only log): ingestion is already idempotent because every event carries a dedup key (`sessionId | message.id | requestId`), and sessionIds are globally unique. Any number of observers may ingest the same remote transcripts in any order; the merge of their books is a set union over dedup keys. This is the founder's remote-server token case, and it is safe by construction — the v1 dedup ledger generalizes to multi-observer without change.
- *Counter sources* (a remote server's `/proc` network and disk counters): counters cannot be deduplicated at event level, because an observer reads a running total, not discrete events. Rule for the first multi-device version: each remote holding is configured on exactly one Mac, its **steward**, so there is again exactly one writer per bucket. A later sync layer can replace the manual steward rule with a lease.

**A Claude Code nuance worth stating.** Transcripts live per-machine under `~/.claude`, so sessions run on Mac 1 are Mac 1's holding and sessions run on the GPU server (over SSH) are the server's holding. The same account being billed does not make the events shared; the files live where the work happened, and the dedup keys keep any overlap honest.

## Agentless remote collection over SSH

A `RemoteHoldingSource` collects for a remote holding using the system `ssh` (BatchMode, a connect timeout, honoring `~/.ssh/config` aliases), running only read-only commands that exist on any stock Linux box:

- Network: `cat /proc/net/dev` for per-interface cumulative bytes, fed through the existing `CounterAccumulator` reset logic.
- Disk: `cat /proc/diskstats` (sectors times 512), deduplicated by device.
- AI tokens: `stat` plus `tail -c +OFFSET` on remote `~/.claude/projects/**/*.jsonl`, parsed locally by the existing `ClaudeCodeParser` and deduplicated by the existing ledger.
- Reset detection: boot id or uptime, so a rebooted server re-baselines instead of producing a wrapped delta.

Nothing is installed remotely; the requirements are an SSH login and POSIX tools. Polling is coarse (30 to 60 seconds). A disconnected holding's accounts read as dormant in the panel, in the same honest voice as the existing "account not yet opened" states — never fake zeroes. Screen time and input have no remote sensors, so those accounts simply stay unopened for remote holdings, which the expense-account framing absorbs cleanly.

## Schema roadmap

These changes should land as schema v3 **before** any remote or sync work, because backfilling is trivial while all existing data is single-origin:

- A `holdings` table: id, name, kind (local or remote), created_at.
- `samples` gains an `origin` column, backfilled to the local holding's id, with the primary key rebuilt to `(origin, day_epoch, minute, kind)` (SQLite requires a table rebuild for a key change; the migration test must prove data survives byte-for-byte).
- Remote cursor state (offsets, inodes, counter baselines) namespaced per holding in `meta`.
- `ai_seen` needs no change; its keys are already globally unique.

## Sync between Macs (decision deferred)

The first multi-device version can ship without any sync: each Mac tracks itself plus the remote holdings it stewards. When sync arrives, the merge rules above make it a state exchange, not a protocol problem: export per-origin day books to a shared folder (for example iCloud Drive), import with newest-per-bucket merge and dedup-key union. No server, no account, consistent with the local-first promise; the books never leave buildings the founder owns.

## Sequencing

1. Schema v3 (origin, holdings registry, key rebuild) plus stamping local samples. Cheap now, expensive later.
2. The SSH remote holding plugin: network, disk, and AI for one remote holding, the steward rule, and a minimal Consolidation view in the General Ledger.
3. File-based sync and merge between Macs.
