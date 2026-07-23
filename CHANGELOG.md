# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] — 2026-07-23

### Added

- **`Ask::State::Providers::SQLite`** — Persistent key-value store backed by SQLite with WAL mode. Supports all `Adapter` primitives: key-value (get/set/delete/set_if_not_exists/clear, TTL), distributed locking (acquire/release with token safety), message queues (FIFO enqueue/dequeue/depth), and ordered lists (append/range/remove with max-length trimming). 58 tests.

- **`Ask::State::Providers::Redis`** — Distributed state store backed by Redis with `ask:state:` key namespace. Uses `SET NX EX` for atomic locking, `RPUSH`/`LPOP` for queues, `LTRIM` for bounded lists, and Lua `EVAL` for safe lock release. 40 tests (tested with fakeredis).

- **`Ask::State::Providers::PostgreSQL`** — State store backed by PostgreSQL with connection pooling, `ON CONFLICT` handling, and `RETURNING` clauses. Tests skip gracefully when `DATABASE_URL` is not set.

- **`Ask::State::Providers::MySQL`** — State store backed by MySQL/MariaDB with prepared statements and `ON DUPLICATE KEY UPDATE`. Tests skip gracefully when `MYSQL_URL` is not set.

- **Autoloading** — All providers use Ruby `autoload` so only the backends you need are loaded.

- **CI** — GitHub Actions workflow testing Ruby 3.2, 3.3, and 3.4.

- **Documentation** — Full README with quick start, backend comparison table, and API reference.
