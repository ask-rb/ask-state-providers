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
      # @example
      #   store = Ask::State::Providers::SQLite.new(path: "sessions.db")
      #   store.set("key", { hello: "world" })
      #   store.get("key")  # => { "hello" => "world" }
      #
      class SQLite < ::Ask::State::Adapter
        # Creates or opens the database at +path+.
        def initialize(path: "sessions.db", **pragmas)
          require "sqlite3"

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
          row = @db.get_first_row(<<~SQL, [key, Time.now.to_f])
            SELECT value FROM state_store
            WHERE key = ? AND (expires_at IS NULL OR expires_at > ?)
          SQL
          row ? JSON.parse(row["value"]) : nil
        end

        def set(key, value, ttl: nil)
          @db.execute(<<~SQL, [key, JSON.generate(value), ttl ? Time.now.to_f + ttl : nil])
            INSERT OR REPLACE INTO state_store (key, value, expires_at)
            VALUES (?, ?, ?)
          SQL
        end

        def delete(key)
          @db.execute("DELETE FROM state_store WHERE key = ?", [key])
        end

        def set_if_not_exists(key, value, ttl: nil)
          now = Time.now.to_f
          expires = ttl ? now + ttl : nil

          @db.transaction do
            row = @db.get_first_row(
              "SELECT 1 FROM state_store WHERE key = ? AND (expires_at IS NULL OR expires_at > ?)",
              [key, now]
            )
            next false if row

            @db.execute("DELETE FROM state_store WHERE key = ?", [key])
            @db.execute(<<~SQL, [key, JSON.generate(value), expires])
              INSERT INTO state_store (key, value, expires_at)
              VALUES (?, ?, ?)
            SQL
            next true
          end
        end

        def clear
          @db.execute("DELETE FROM state_store")
        end

        # -- distributed locking --

        def acquire_lock(key, ttl: 10)
          now = Time.now.to_f
          expires_at_time = Time.now + ttl
          token = SecureRandom.hex(16)

          acquired = @db.transaction do
            row = @db.get_first_row(
              "SELECT 1 FROM locks WHERE key = ? AND expires_at > ?",
              [key, now]
            )
            next false if row

            @db.execute("DELETE FROM locks WHERE key = ?", [key])
            @db.execute(<<~SQL, [key, expires_at_time.to_f, token])
              INSERT INTO locks (key, expires_at, token)
              VALUES (?, ?, ?)
            SQL
            next true
          end

          acquired ? Lock.new(id: key, token: token, expires_at: expires_at_time) : nil
        end

        def release_lock(key, lock)
          @db.execute(
            "DELETE FROM locks WHERE key = ? AND token = ?",
            [key, lock.token]
          )
          @db.changes > 0
        end

        # -- message queues --

        def enqueue(queue, value)
          @db.execute(<<~SQL, [queue, JSON.generate(value), Time.now.iso8601])
            INSERT INTO queues (queue_name, value, enqueued_at)
            VALUES (?, ?, ?)
          SQL
          id = @db.last_insert_row_id
          QueueEntry.new(id: id.to_s, value: value, enqueued_at: Time.now)
        end

        def dequeue(queue)
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

        def queue_depth(queue)
          row = @db.get_first_row(
            "SELECT COUNT(*) AS cnt FROM queues WHERE queue_name = ?", [queue]
          )
          row["cnt"]
        end

        # -- ordered lists --

        def list_append(key, value, max_length: nil)
          serialized = JSON.generate(value)

          @db.execute(<<~SQL, [key, serialized])
            INSERT INTO lists (list_key, value)
            VALUES (?, ?)
          SQL

          return unless max_length

          # Keep only the newest max_length items by deleting those with the
          # smallest id values beyond the threshold
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

        def list_range(key, start = 0, stop = -1)
          if stop == -1
            rows = @db.execute(<<~SQL, [key, start])
              SELECT value FROM lists
              WHERE list_key = ?
              ORDER BY id ASC
              LIMIT -1 OFFSET ?
            SQL
          else
            limit = stop - start + 1
            rows = @db.execute(<<~SQL, [key, limit, start])
              SELECT value FROM lists
              WHERE list_key = ?
              ORDER BY id ASC
              LIMIT ? OFFSET ?
            SQL
          end
          rows.map { |r| JSON.parse(r["value"]) }
        end

        def list_remove(key, value)
          serialized = JSON.generate(value)
          @db.execute(
            "DELETE FROM lists WHERE list_key = ? AND value = ?",
            [key, serialized]
          )
          @db.changes
        end

        # -- lifecycle --

        def close
          @db.close
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
