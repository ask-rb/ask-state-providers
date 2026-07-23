# frozen_string_literal: true

require "json"
require "time"
require "securerandom"

module Ask
  module State
    module Providers
      # A persistent key-value store backed by PostgreSQL.
      #
      # Implements the full {Ask::State::Adapter} contract:
      # key-value storage, distributed locking, message queues, and ordered
      # lists. Uses the +pg+ gem for database access.
      #
      # @example
      #   store = Ask::State::Providers::Postgres.new(
      #     url: ENV["DATABASE_URL"]
      #   )
      #   store.set("key", { hello: "world" })
      #   store.get("key")  # => { "hello" => "world" }
      #
      class Postgres < ::Ask::State::Adapter
        MIGRATIONS = <<~SQL
          CREATE TABLE IF NOT EXISTS state_store (
            key         TEXT PRIMARY KEY NOT NULL,
            value       TEXT NOT NULL,
            expires_at  TIMESTAMPTZ
          );

          CREATE TABLE IF NOT EXISTS locks (
            key         TEXT PRIMARY KEY NOT NULL,
            token       TEXT NOT NULL,
            expires_at  TIMESTAMPTZ NOT NULL
          );

          CREATE TABLE IF NOT EXISTS queues (
            id           BIGSERIAL PRIMARY KEY,
            queue_name   TEXT NOT NULL,
            value        TEXT NOT NULL,
            enqueued_at  TIMESTAMPTZ NOT NULL
          );
          CREATE INDEX IF NOT EXISTS idx_queues_queue_name
            ON queues (queue_name, id);

          CREATE TABLE IF NOT EXISTS lists (
            id         BIGSERIAL PRIMARY KEY,
            list_key   TEXT NOT NULL,
            value      TEXT NOT NULL
          );
          CREATE INDEX IF NOT EXISTS idx_lists_list_key
            ON lists (list_key, id);
        SQL

        # Creates a new PostgreSQL-backed state store.
        #
        # @param url [String] Postgres connection URL
        # @param pool_size [Integer] connection pool size (default 5)
        def initialize(url: ENV.fetch("DATABASE_URL", "postgres://localhost:5432/ask_state"),
                       pool_size: 5)
          require "pg"

          @pool = ConnectionPool.new(size: pool_size) do
            ::PG.connect(url)
          end

          migrate
        end

        # -- key-value --

        def get(key)
          @pool.with do |conn|
            row = conn.exec_params(<<~SQL, [key, Time.now.utc])
              SELECT value FROM state_store
              WHERE key = $1 AND (expires_at IS NULL OR expires_at > $2)
            SQL
            row.ntuples > 0 ? JSON.parse(row[0]["value"]) : nil
          end
        end

        def set(key, value, ttl: nil)
          @pool.with do |conn|
            conn.exec_params(<<~SQL, [key, JSON.generate(value), ttl ? Time.now.utc + ttl : nil])
              INSERT INTO state_store (key, value, expires_at)
              VALUES ($1, $2, $3)
              ON CONFLICT (key) DO UPDATE SET
                value = EXCLUDED.value,
                expires_at = EXCLUDED.expires_at
            SQL
          end
        end

        def delete(key)
          @pool.with do |conn|
            conn.exec_params("DELETE FROM state_store WHERE key = $1", [key])
          end
        end

        def set_if_not_exists(key, value, ttl: nil)
          @pool.with do |conn|
            now = Time.now.utc
            expires = ttl ? now + ttl : nil

            result = conn.exec_params(<<~SQL, [key, JSON.generate(value), expires, now])
              INSERT INTO state_store (key, value, expires_at)
              SELECT $1, $2, $3
              WHERE NOT EXISTS (
                SELECT 1 FROM state_store
                WHERE key = $1 AND (expires_at IS NULL OR expires_at > $4)
              )
              ON CONFLICT (key) DO NOTHING
            SQL
            result.cmd_tuples > 0
          end
        end

        def clear
          @pool.with { |conn| conn.exec("DELETE FROM state_store") }
        end

        # -- distributed locking --

        def acquire_lock(key, ttl: 10)
          now = Time.now.utc
          expires_at_time = now + ttl
          token = SecureRandom.hex(16)

          acquired = @pool.with do |conn|
            # First clean up expired locks
            conn.exec_params("DELETE FROM locks WHERE key = $1 AND expires_at <= $2",
                           [key, now])

            result = conn.exec_params(<<~SQL, [key, expires_at_time, token, now])
              INSERT INTO locks (key, expires_at, token)
              SELECT $1, $2, $3
              WHERE NOT EXISTS (
                SELECT 1 FROM locks
                WHERE key = $1
              )
            SQL
            result.cmd_tuples > 0
          end

          acquired ? Lock.new(id: key, token: token, expires_at: expires_at_time) : nil
        end

        def release_lock(key, lock)
          @pool.with do |conn|
            result = conn.exec_params(
              "DELETE FROM locks WHERE key = $1 AND token = $2",
              [key, lock.token]
            )
            result.cmd_tuples > 0
          end
        end

        # -- message queues --

        def enqueue(queue, value)
          id = SecureRandom.uuid

          @pool.with do |conn|
            conn.exec_params(<<~SQL, [queue, JSON.generate(value), Time.now.utc])
              INSERT INTO queues (queue_name, value, enqueued_at)
              VALUES ($1, $2, $3)
            SQL
          end

          QueueEntry.new(id: id, value: value, enqueued_at: Time.now)
        end

        def dequeue(queue)
          @pool.with do |conn|
            result = conn.exec_params(<<~SQL, [queue])
              DELETE FROM queues
              WHERE id = (
                SELECT id FROM queues
                WHERE queue_name = $1
                ORDER BY id ASC
                LIMIT 1
              )
              RETURNING value, enqueued_at
            SQL
            return nil if result.ntuples == 0

            QueueEntry.new(
              id: SecureRandom.uuid,
              value: JSON.parse(result[0]["value"]),
              enqueued_at: Time.parse(result[0]["enqueued_at"])
            )
          end
        end

        def queue_depth(queue)
          @pool.with do |conn|
            result = conn.exec_params(
              "SELECT COUNT(*) AS cnt FROM queues WHERE queue_name = $1", [queue]
            )
            result[0]["cnt"].to_i
          end
        end

        # -- ordered lists --

        def list_append(key, value, max_length: nil)
          @pool.with do |conn|
            conn.exec_params(<<~SQL, [key, JSON.generate(value)])
              INSERT INTO lists (list_key, value)
              VALUES ($1, $2)
            SQL

            return unless max_length

            conn.exec_params(<<~SQL, [key, key, max_length])
              DELETE FROM lists WHERE id <= (
                SELECT COALESCE(MIN(id), 0) FROM (
                  SELECT id FROM lists
                  WHERE list_key = $1
                  ORDER BY id DESC
                  LIMIT $3
                ) sub
              )
            SQL
          end
        end

        def list_range(key, start = 0, stop = -1)
          @pool.with do |conn|
            rows = if stop == -1
              conn.exec_params(<<~SQL, [key, start])
                SELECT value FROM lists
                WHERE list_key = $1
                ORDER BY id ASC
                OFFSET $2
              SQL
            else
              limit = stop - start + 1
              conn.exec_params(<<~SQL, [key, limit, start])
                SELECT value FROM lists
                WHERE list_key = $1
                ORDER BY id ASC
                LIMIT $2 OFFSET $3
              SQL
            end
            rows.map { |r| JSON.parse(r["value"]) }
          end
        end

        def list_remove(key, value)
          serialized = JSON.generate(value)
          @pool.with do |conn|
            result = conn.exec_params(
              "DELETE FROM lists WHERE list_key = $1 AND value = $2",
              [key, serialized]
            )
            result.cmd_tuples
          end
        end

        # -- lifecycle --

        def close
          @pool&.shutdown { |c| c.close }
        end

        private

        def migrate
          @pool.with { |conn| conn.exec(MIGRATIONS) }
        end
      end
    end
  end
end
