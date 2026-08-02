# ask-state-providers

[![Gem Version](https://badge.fury.io/rb/ask-state-providers.svg)](https://badge.fury.io/rb/ask-state-providers)

Pluggable state backends for the ask-rb ecosystem. One `Ask::State::Adapter` contract, five backends: in-memory Memory, SQLite, Redis, Postgres, and MySQL. `Ask::State::Memory`, the in-process default, lives in this gem since 0.3.0.

## Installation

```ruby
gem "ask-state-providers"
```

Add the driver gem for the backend you use:

```ruby
gem "sqlite3"   # SQLite
gem "redis"     # Redis
gem "pg"        # PostgreSQL
gem "mysql2"    # MySQL
```

## Quick Start

```ruby
require "ask-state-providers"

store = Ask::State::Memory.new        # in-process, no persistence
# store = Ask::State::Providers::SQLite.new(path: "sessions.db")
# store = Ask::State::Providers::Redis.new(url: ENV["REDIS_URL"])
# store = Ask::State::Providers::Postgres.new(url: ENV["DATABASE_URL"])
# store = Ask::State::Providers::MySQL.new(url: ENV["MYSQL_URL"])

store.set("user:1", { name: "Alice", role: "admin" }, ttl: 3600)
store.get("user:1")                   # => { "name" => "Alice", "role" => "admin" }
store.set_if_not_exists("lock:deploy", "in_progress")
store.acquire_lock("deploy-prod", ttl: 60)
store.enqueue("tasks", { action: "send_email" })
store.dequeue("tasks")
store.list_append("recent_events", "event-1", max_length: 100)
store.list_range("recent_events", 0, 9)
store.delete("user:1")
```

## Backends

| Backend | Constructor | Notes |
|---|---|---|
| `Ask::State::Memory` | `Memory.new` | In-memory, thread-safe, lost on process exit |
| `Ask::State::Providers::SQLite` | `SQLite.new(path: "sessions.db")` | Single file, WAL mode, tables auto-created |
| `Ask::State::Providers::Redis` | `Redis.new(url:)` | Keys namespaced under `ask:state:` |
| `Ask::State::Providers::Postgres` | `Postgres.new(url:, pool_size: 5)` | Built-in connection pool |
| `Ask::State::Providers::MySQL` | `MySQL.new(url:)` | `utf8mb4` character set |

## Adapter contract

Every backend implements `Ask::State::Adapter`:

- Key-value: `get`, `set(key, value, ttl:)`, `delete`, `set_if_not_exists`, `keys(pattern:)`, `clear`
- Distributed locking: `acquire_lock(key, ttl:)`, `release_lock(key, lock)`
- Message queues: `enqueue(queue, value)`, `dequeue(queue)`
- Ordered lists: `list_append(key, value, max_length:)`, `list_range(key, start, stop)`, `list_remove(key, value)`

## Full documentation

The full ask-rb documentation lives at https://ask-rb.github.io/ask-docs. [ask-state-providers in depth](https://ask-rb.github.io/ask-docs/reference/api#ask-state-providers) covers the adapter contract and backends. API reference: https://ask-rb.github.io/ask-docs/reference/api.

## Development

```
bundle install
bundle exec rake test
```

## License

MIT
