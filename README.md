# ask-state-providers

Pluggable state backends for the [ask-rb](https://github.com/ask-rb) ecosystem. Provides `Ask::State::Adapter` implementations for **SQLite**, **Redis**, **PostgreSQL**, and **MySQL** — one interface, four databases, zero coupling to your infrastructure.

```ruby
# Local dev — zero config
store = Ask::State::Providers::SQLite.new

# In production with Rails
store = Ask::State::Providers::Redis.new(url: ENV["REDIS_URL"])

# With your existing database
store = Ask::State::Providers::Postgres.new(url: ENV["DATABASE_URL"])
```

## Why?

ask-rb agents and sessions need to persist state — conversations, tool results, locks, task queues. Each deployment has different infrastructure: a CLI tool needs SQLite, a Rails app already has Postgres, a distributed system needs Redis. Instead of baking one backend into ask-core, this gem provides them all as drop-in adapters behind the same `Ask::State::Adapter` contract.

## Installation

Add this line to your `Gemfile`:

```ruby
gem "ask-state-providers"
```

Then add the database driver for the backend you want to use:

```ruby
# For SQLite (ships with Ruby's standard library — no extra gem needed on most systems)
gem "sqlite3"

# For Redis
gem "redis"

# For PostgreSQL
gem "pg"

# For MySQL
gem "mysql2"
```

## Quick Start

```ruby
require "ask-state-providers"

# Pick your backend:
store = Ask::State::Providers::SQLite.new(path: "my_app.db")
# store = Ask::State::Providers::Redis.new(url: ENV["REDIS_URL"])
# store = Ask::State::Providers::Postgres.new(url: ENV["DATABASE_URL"])
# store = Ask::State::Providers::MySQL.new(url: ENV["MYSQL_URL"])

# Key-value storage
store.set("user:1", { name: "Alice", role: "admin" })
store.get("user:1")         # => {"name" => "Alice", "role" => "admin"}
store.set("temp", "expires", ttl: 3600)  # auto-expires in 1 hour
store.delete("user:1")

# Conditional create
store.set_if_not_exists("lock:deploy", "in_progress")

# Distributed locking
lock = store.acquire_lock("deploy-prod", ttl: 60)
store.release_lock("deploy-prod", lock) if lock

# Message queues
store.enqueue("tasks", { action: "send_email" })
task = store.dequeue("tasks")

# Ordered lists
store.list_append("recent_events", event, max_length: 100)
store.list_range("recent_events", 0, 9)  # first 10
```

## Backends

### SQLite (`Ask::State::Providers::SQLite`)

Best for single-process, single-user applications — CLI tools, local development, personal agents.

| Feature | Detail |
|---------|--------|
| **Driver** | [`sqlite3`](https://github.com/sparklemotion/sqlite3-ruby) |
| **Configuration** | `SQLite.new(path:)` |
| **Storage** | Single file on disk |
| **Concurrency** | WAL mode with 5-second busy timeout |
| **Tables** | `state_store`, `locks`, `queues`, `lists` (auto-created) |

Uses `INSERT OR REPLACE` for key-value, `INSERT ... WHERE NOT EXISTS` for conditional writes, and `DELETE ... RETURNING` for safe queue dequeue.

### Redis (`Ask::State::Providers::Redis`)

Best for distributed, multi-process, or multi-host deployments.

| Feature | Detail |
|---------|--------|
| **Driver** | [`redis`](https://github.com/redis-rb/redis-rb) |
| **Configuration** | `Redis.new(url:)` |
| **Storage** | In-memory with optional persistence |
| **Key prefix** | `ask:state:` (all keys are namespaced) |

Leverages Redis-native primitives: `SET NX EX` for atomic locking with auto-expire, `RPUSH`/`LPOP` for FIFO queues, `LTRIM` for bounded lists, Lua `EVAL` for safe lock release.

### PostgreSQL (`Ask::State::Providers::Postgres`)

Best for Rails apps and deployments already running Postgres.

| Feature | Detail |
|---------|--------|
| **Driver** | [`pg`](https://github.com/ged/ruby-pg) |
| **Configuration** | `Postgres.new(url:)` |
| **Connection pool** | Built-in via `connection_pool` (default pool size: 5) |

Uses `ON CONFLICT`, `RETURNING`, and `INSERT ... WHERE NOT EXISTS` for safe concurrent access.

### MySQL (`Ask::State::Providers::MySQL`)

Best for teams already running MySQL or MariaDB.

| Feature | Detail |
|---------|--------|
| **Driver** | [`mysql2`](https://github.com/brianmario/mysql2) |
| **Configuration** | `MySQL.new(url:)` |
| **Character set** | `utf8mb4` (full Unicode including emoji) |

Uses prepared statements, `ON DUPLICATE KEY UPDATE`, and `SELECT ... LIMIT 1` for safe dequeue.

## API Reference

All backends implement `Ask::State::Adapter`:

### Key-Value

| Method | Description |
|--------|-------------|
| `get(key)` | Retrieve a value, or `nil` if missing or expired |
| `set(key, value, ttl:)` | Store a value (JSON-serializable). `ttl` in seconds |
| `delete(key)` | Remove a key |
| `set_if_not_exists(key, value, ttl:)` | Create only if key doesn't exist (or is expired). Returns `true`/`false` |
| `clear` | Remove all keys |

### Distributed Locking

| Method | Description |
|--------|-------------|
| `acquire_lock(key, ttl:)` | Acquire a lock. Returns `Lock` or `nil` |
| `release_lock(key, lock)` | Release a lock (only the owner can). Returns `true`/`false` |

### Message Queues

| Method | Description |
|--------|-------------|
| `enqueue(queue, value)` | Push to the back of a queue. Returns `QueueEntry` |
| `dequeue(queue)` | Pop from the front of a queue. Returns `QueueEntry` or `nil` |
| `queue_depth(queue)` | Number of items in the queue |

### Ordered Lists

| Method | Description |
|--------|-------------|
| `list_append(key, value, max_length:)` | Append to list. Trims to `max_length` (keeps newest) |
| `list_range(key, start, stop)` | Slice of the list. `stop = -1` means all |
| `list_remove(key, value)` | Remove all occurrences. Returns count removed |

### Lifecycle

| Method | Description |
|--------|-------------|
| `close` | Close the connection(s) |

## Using with ask-agent Sessions

```ruby
require "ask-state-providers"
require "ask-agent"

store = Ask::State::Providers::SQLite.new

session = Ask::Agent::Session.new(
  "triage",
  model: "gpt-4o",
  state: store
)

session.run("What happened last time we saw this error?")
# Every turn is persisted — survive restarts, searchable, auditable
```

## Development

```bash
# Install dependencies
bundle install

# Run tests (SQLite tests run everywhere, Redis needs fakeredis,
# Postgres/MySQL need DATABASE_URL/MYSQL_URL env vars)
bundle exec rake test

# Run tests with verbose output
bundle exec ruby -Itest test/ask/state/providers/sqlite_test.rb
bundle exec ruby -Itest test/ask/state/providers/redis_test.rb

# Test Postgres locally
DATABASE_URL="postgres://localhost:5432/ask_state_test" bundle exec rake test

# Test MySQL locally
MYSQL_URL="mysql2://root@localhost:3306/ask_state_test" bundle exec rake test
```

## License

MIT — see [LICENSE](LICENSE).

## Links

- **Source:** https://github.com/ask-rb/ask-state-providers
- **Issues:** https://github.com/ask-rb/ask-state-providers/issues
- **Docs:** https://github.com/ask-rb/ask-docs
