# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [0.4.8] — 2026-09-22

### Changed

- **Minimum `ask-core` raised to `>= 0.12.0`** (was `>= 0.11.4`) — aligns
  the provider stack with the decision-vocabulary release of `ask-core`.

### Fixed

- **Provider lock contract hardened (token-safe release, TTL/expiry, cross-backend parity)**:

  - **MySQL `acquire_lock` no longer hands a second contender a lock.**
    Success was decided by `COUNT(*) > 0` on the key, so while an owner
    held the lock, the next `acquire_lock` also returned a `Lock` —
    exclusion was broken. It now uses one conditional upsert
    (`ON DUPLICATE KEY UPDATE` that only takes over expired rows) and
    reports success from `affected_rows`.
  - **SQLite `acquire_lock` is atomic across processes.** The old
    SELECT-then-DELETE-then-INSERT could delete a lock another process
    had just granted. Replaced with a single
    `INSERT … ON CONFLICT DO UPDATE … WHERE expires_at <= now
    RETURNING token` that only takes over expired rows.
  - **Postgres `acquire_lock` no longer races into `UniqueViolation`.**
    DELETE-then-`INSERT … WHERE NOT EXISTS` let concurrent callers
    collide on the primary key and raise instead of returning `nil`.
    Now one `ON CONFLICT DO UPDATE … WHERE` upsert, verified by
    `RETURNING token`.
  - **Redis `acquire_lock` accepts non-positive TTLs.**
    `SET … EX 0/-1` raised `invalid expire time`; it now returns an
    already-expired lock without writing (and refuses when a live lock
    is held), matching the SQL backends. Uses `PX` so whole-second and
    sub-second TTLs share one path.
  - **SQLite/Postgres/MySQL `release_lock` respects expiry.** They
    deleted by key+token alone and returned `true` for an
    expired-but-unreaped lock; the `Adapter` contract (and Memory/Redis)
    return `false` once expired. Release now requires a matching token
    **and** an unexpired lock.

### Tests

- **Shared `AdapterContract` lock coverage expanded** — five new
  contract tests run against Memory, SQLite, Redis, Postgres, and MySQL:
  release-after-expiry returns `false`, double release fails, a stale
  owner cannot release the lock's replacement, `ttl: 0` grants no
  exclusion, and `ttl:` lands in `expires_at`. Redis's
  `test_lock_expired_can_be_acquired` skip is removed, and
  `Ask::State::Memory` now runs the full shared contract
  (`memory_contract_test.rb`).

## [0.4.1] — 2026-08-12

### Fixed

- **`delete(key)` now removes everything under the key** — including
  ordered lists (and queues in the Memory backend). Consumers store event
  feeds as lists (ask-workflow's project store, the app-server session
  store); previously the feed survived deletion. New shared contract test
  `test_delete_removes_list_entries` runs against every provider.

## [0.3.0] — 2026-07-28

### Added

- **`Ask::State::Memory`** — in-memory state backend, moved from `ask-core`. Same class name, same API. Requires `require "ask-state-providers"` instead of `require "ask"`.

  ```ruby
  require "ask-state-providers"
  store = Ask::State::Memory.new
  ```

## [0.2.0] — 2026-07-23

### Changed

- **BREAKING:** Removed `SessionPersistence` wrapper class — no longer needed. Session accepts `State::Adapter` directly via `state:` keyword.
- **BREAKING:** `Session.load` now calls `adapter.get(id)` instead of `adapter.load(id)`. Any custom adapter must respond to `get`/`set`/`delete`.

### Added

- **Shared contract test suite** — `AdapterContract` module with 26 tests that every backend must pass. Runs against SQLite, Redis (via fakeredis), Postgres (when `DATABASE_URL` is set), and MySQL (when `MYSQL_URL` is set).
- **Per-turn persistence** — Session now persists after every LLM turn, not just at the end of `run()`. Mid-session crashes no longer lose progress.
- **`Session.load` restores `@messages`** — Previously `session.messages` returned `nil` after loading. Now it's populated from the restored chat messages.

### Fixed

- **README** — Updated `persistence:` example to `state:`.

## [0.1.0] — 2026-07-23

### Added

- **`Ask::State::Providers::SQLite`** — Persistent key-value store backed by SQLite with WAL mode. Supports all `Adapter` primitives: key-value (get/set/delete/set_if_not_exists/clear, TTL), distributed locking (acquire/release with token safety), message queues (FIFO enqueue/dequeue/depth), and ordered lists (append/range/remove with max-length trimming). 58 tests.

- **`Ask::State::Providers::Redis`** — Distributed state store backed by Redis with `ask:state:` key namespace. Uses `SET NX EX` for atomic locking, `RPUSH`/`LPOP` for queues, `LTRIM` for bounded lists, and Lua `EVAL` for safe lock release. 40 tests (tested with fakeredis).

- **`Ask::State::Providers::PostgreSQL`** — State store backed by PostgreSQL with connection pooling, `ON CONFLICT` handling, and `RETURNING` clauses. Tests skip gracefully when `DATABASE_URL` is not set.

- **`Ask::State::Providers::MySQL`** — State store backed by MySQL/MariaDB with prepared statements and `ON DUPLICATE KEY UPDATE`. Tests skip gracefully when `MYSQL_URL` is not set.

- **Autoloading** — All providers use Ruby `autoload` so only the backends you need are loaded.

- **CI** — GitHub Actions workflow testing Ruby 3.2, 3.3, and 3.4.

- **Documentation** — Full README with quick start, backend comparison table, and API reference.
