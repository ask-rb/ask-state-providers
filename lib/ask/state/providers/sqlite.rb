# frozen_string_literal: true

require "json"
require "time"
require "securerandom"

module Ask
  module State
    module Providers
      # A persistent key-value store backed by SQLite.
      #
      # Implements the full {Ask::State::Adapter} contract:
      # key-value storage, distributed locking, message queues, and ordered
      # lists. Uses the +sqlite3+ gem.
      #
      # Thread-safe via internal Mutex.
      #
      # @example
      #   store = Ask::State::Providers::SQLite.new(path: "sessions.db")
      #   store.set("key", { hello: "world" })
      #   store.get("key")  # => { "hello" => "world" }
      #
      class SQLite < ::Ask::State::Adapter
        # Creates or opens the database at +path+.
        def initialize(path: "sessions.db", **pragmas)
          require "sqlite3"

          @mutex = Mutex.new
          @db = SQLite3::Database.new(path)
          @db.results_as_hash = true
          @db.busy_timeout = 5000

          defaults = {
            journal_mode: "WAL",
            synchronous: "NORMAL",
            foreign_keys: "ON",
            cache_size: -64_000
          }

          defaults.merge(pragmas).each do |key, value|
            @db.execute("PRAGMA #{key} = #{value}")
          end

          migrate
        end

        # -- key-value --

        def get(key)
          @mutex.synchronize do
            row = @db.get_first_row(<<~SQL, [key, Time.now.to_f])
              SELECT value FROM state_store
              WHERE key = ? AND (expires_at IS NULL OR expires_at > ?)
            SQL
            row ? JSON.parse(row["value"]) : nil
          end
        end

        def set(key, value, ttl: nil)
          @mutex.synchronize do
            @db.execute(<<~SQL, [key, JSON.generate(value), ttl ? Time.now.to_f + ttl : nil])
              INSERT OR REPLACE INTO state_store (key, value, expires_at)
              VALUES (?, ?, ?)
            SQL
          end
        end

        def delete(key)
          @mutex.synchronize do
            @db.execute("DELETE FROM state_store WHERE key = ?", [key])
          end
        end

        def set_if_not_exists(key, value, ttl: nil)
          @mutex.synchronize do
            now = Time.now.to_f
            expires = ttl ? now + ttl : nil

            row = @db.get_first_row(
              "SELECT 1 FROM state_store WHERE key = ? AND (expires_at IS NULL OR expires_at > ?)",
              [key, now]
            )
            return false if row

            # Key doesn't exist or is expired — delete any leftovers, then insert
            @db.execute("DELETE FROM state_store WHERE key = ?", [key])
            @db.execute(<<~SQL, [key, JSON.generate(value), expires])
              INSERT INTO state_store (key, value, expires_at)
              VALUES (?, ?, ?)
            SQL
            true
          end
        end

        def clear
          @mutex.synchronize do
            @db.execute("DELETE FROM state_store")
            @db.execute("DELETE FROM locks")
            @db.execute("DELETE FROM queues")
            @db.execute("DELETE FROM lists")
          end
        end

        def exists?(key)
          @mutex.synchronize do
            row = @db.get_first_row(<<~SQL, [key, Time.now.to_f])
              SELECT 1 FROM state_store
              WHERE key = ? AND (expires_at IS NULL OR expires_at > ?)
            SQL
            !row.nil?
          end
        end

        def keys(pattern: nil)
          @mutex.synchronize do
            now = Time.now.to_f
            sql, params = if pattern
              like = pattern.gsub("*", "%").gsub("?", "_")
              [<<~SQL, [like, now]]
                SELECT key FROM state_store
                WHERE key LIKE ? AND (expires_at IS NULL OR expires_at > ?)
              SQL
            else
              [<<~SQL, [now]]
                SELECT key FROM state_store
                WHERE (expires_at IS NULL OR expires_at > ?)
              SQL
            end
            @db.execute(sql, params).map { |r| r["key"] }
          end
        end

        # -- distributed locking --

        def acquire_lock(key, ttl: 10)
          @mutex.synchronize do
            now = Time.now.to_f
            expires_at_time = Time.now + ttl
            token = SecureRandom.hex(16)

            row = @db.get_first_row(
              "SELECT 1 FROM locks WHERE key = ? AND expires_at > ?",
              [key, now]
            )
            return nil if row

            @db.execute("DELETE FROM locks WHERE key = ?", [key])
            @db.execute(<<~SQL, [key, expires_at_time.to_f, token])
              INSERT INTO locks (key, expires_at, token)
              VALUES (?, ?, ?)
            SQL

            Lock.new(id: key, token: token, expires_at: expires_at_time)
          end
        end

        def release_lock(key, lock)
          @mutex.synchronize do
            @db.execute(
              "DELETE FROM locks WHERE key = ? AND token = ?",
              [key, lock.token]
            )
            @db.changes > 0
          end
        end

        # -- message queues --

        def enqueue(queue, value)
          @mutex.synchronize do
            @db.execute(<<~SQL, [queue, JSON.generate(value), Time.now.iso8601])
              INSERT INTO queues (queue_name, value, enqueued_at)
              VALUES (?, ?, ?)
            SQL
            id = @db.last_insert_row_id
            QueueEntry.new(id: id.to_s, value: value, enqueued_at: Time.now)
          end
        end

        def dequeue(queue)
          @mutex.synchronize do
            row = @db.get_first_row(<<~SQL, [queue])
              DELETE FROM queues
              WHERE id = (
                SELECT id FROM queues
                WHERE queue_name = ?
                ORDER BY id ASC
                LIMIT 1
              )
              RETURNING id, value, enqueued_at
            SQL
            return nil unless row

            QueueEntry.new(
              id: row["id"].to_s,
              value: JSON.parse(row["value"]),
              enqueued_at: Time.parse(row["enqueued_at"])
            )
          end
        end

        def queue_depth(queue)
          @mutex.synchronize do
            row = @db.get_first_row(
              "SELECT COUNT(*) AS cnt FROM queues WHERE queue_name = ?", [queue]
            )
            row["cnt"]
          end
        end

        # -- ordered lists --

        def list_append(key, value, max_length: nil)
          @mutex.synchronize do
            serialized = JSON.generate(value)

            @db.execute(<<~SQL, [key, serialized])
              INSERT INTO lists (list_key, value)
              VALUES (?, ?)
            SQL

            return unless max_length

            row = @db.get_first_row(<<~SQL, [key, max_length])
              SELECT MIN(id) AS cutoff FROM (
                SELECT id FROM lists
                WHERE list_key = ?
                ORDER BY id DESC
                LIMIT ?
              )
            SQL
            return unless row && row["cutoff"]

            @db.execute(<<~SQL, [key, row["cutoff"]])
              DELETE FROM lists WHERE list_key = ? AND id < ?
            SQL
          end
        end

        def list_range(key, start = 0, stop = -1)
          @mutex.synchronize do
            rows = if stop == -1
              @db.execute(<<~SQL, [key, start])
                SELECT value FROM lists
                WHERE list_key = ?
                ORDER BY id ASC
                LIMIT -1 OFFSET ?
              SQL
            else
              limit = stop - start + 1
              @db.execute(<<~SQL, [key, limit, start])
                SELECT value FROM lists
                WHERE list_key = ?
                ORDER BY id ASC
                LIMIT ? OFFSET ?
              SQL
            end
            rows.map { |r| JSON.parse(r["value"]) }
          end
        end

        def list_remove(key, value)
          @mutex.synchronize do
            serialized = JSON.generate(value)
            @db.execute(
              "DELETE FROM lists WHERE list_key = ? AND value = ?",
              [key, serialized]
            )
            @db.changes
          end
        end

        # -- lifecycle --

        def close
          @mutex.synchronize do
            @db.close
          end
        end

        private

        def migrate
          @db.execute_batch(<<~SQL)
            CREATE TABLE IF NOT EXISTS state_store (
              key         TEXT PRIMARY KEY NOT NULL,
              value       TEXT NOT NULL,
              expires_at  REAL
            );

            CREATE TABLE IF NOT EXISTS locks (
              key         TEXT PRIMARY KEY NOT NULL,
              token       TEXT NOT NULL,
              expires_at  REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS queues (
              id           INTEGER PRIMARY KEY AUTOINCREMENT,
              queue_name   TEXT NOT NULL,
              value        TEXT NOT NULL,
              enqueued_at  TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_queues_queue_name
              ON queues (queue_name, id);

            CREATE TABLE IF NOT EXISTS lists (
              id         INTEGER PRIMARY KEY AUTOINCREMENT,
              list_key   TEXT NOT NULL,
              value      TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_lists_list_key
              ON lists (list_key, id);
          SQL
        end
      end
    end
  end
end
