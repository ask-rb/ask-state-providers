# Changelog

All notable changes to this project will be documented in this file.

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
