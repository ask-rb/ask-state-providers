# frozen_string_literal: true

require "json"
require "time"
require "securerandom"

module Ask
  module State
    module Providers
      # A persistent key-value store backed by MySQL.
      #
      # Implements the full {Ask::State::Adapter} contract:
      # key-value storage, distributed locking, message queues, and ordered
      # lists. Uses the +mysql2+ gem for database access.
      #
      # @example
      #   store = Ask::State::Providers::MySQL.new(
      #     url: ENV["MYSQL_URL"]
      #   )
      #   store.set("key", { hello: "world" })
      #   store.get("key")  # => { "hello" => "world" }
      #
      class MySQL < ::Ask::State::Adapter
        MIGRATIONS = <<~SQL
          CREATE TABLE IF NOT EXISTS state_store (
            `key`       VARCHAR(255) PRIMARY KEY NOT NULL,
            `value`     TEXT NOT NULL,
            expires_at  DATETIME(3) NULL
          ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

          CREATE TABLE IF NOT EXISTS locks (
            `key`       VARCHAR(255) PRIMARY KEY NOT NULL,
            token       VARCHAR(64) NOT NULL,
            expires_at  DATETIME(3) NOT NULL
          ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

          CREATE TABLE IF NOT EXISTS queues (
            id           BIGINT AUTO_INCREMENT PRIMARY KEY,
            queue_name   VARCHAR(255) NOT NULL,
            `value`      TEXT NOT NULL,
            enqueued_at  DATETIME(3) NOT NULL,
            INDEX idx_queues_queue_name (queue_name, id)
          ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

          CREATE TABLE IF NOT EXISTS lists (
            id         BIGINT AUTO_INCREMENT PRIMARY KEY,
            list_key   VARCHAR(255) NOT NULL,
            `value`    TEXT NOT NULL,
            INDEX idx_lists_list_key (list_key, id)
          ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        SQL

        # Creates a new MySQL-backed state store.
        #
        # @param url [String] MySQL connection URL
        def initialize(url: ENV.fetch("MYSQL_URL", "mysql2://root@localhost:3306/ask_state"))
          require "mysql2"

          uri = URI.parse(url)
          @client = Mysql2::Client.new(
            host: uri.host || "localhost",
            port: uri.port || 3306,
            username: uri.user || "root",
            password: uri.password,
            database: uri.path.sub("/", ""),
            charset: "utf8mb4"
          )

          migrate
        end

        # -- key-value --

        def get(key)
          row = @client.prepare(<<~SQL).execute(key, Time.now.utc.strftime("%Y-%m-%d %H:%M:%S.%3N")).first
            SELECT `value` FROM state_store
            WHERE `key` = ? AND (expires_at IS NULL OR expires_at > ?)
          SQL
          row ? JSON.parse(row["value"]) : nil
        end

        def set(key, value, ttl: nil)
          stmt = @client.prepare(<<~SQL)
            INSERT INTO state_store (`key`, `value`, expires_at)
            VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE
              `value` = VALUES(`value`),
              expires_at = VALUES(expires_at)
          SQL
          stmt.execute(key, JSON.generate(value), ttl ? (Time.now.utc + ttl).strftime("%Y-%m-%d %H:%M:%S.%3N") : nil)
        end

        def delete(key)
          @client.prepare("DELETE FROM state_store WHERE `key` = ?").execute(key)
        end

        def set_if_not_exists(key, value, ttl: nil)
          now = Time.now.utc
          expires = ttl ? (now + ttl).strftime("%Y-%m-%d %H:%M:%S.%3N") : nil
          now_f = now.strftime("%Y-%m-%d %H:%M:%S.%3N")

          stmt = @client.prepare(<<~SQL)
            INSERT INTO state_store (`key`, `value`, expires_at)
            SELECT ?, ?, ?
            WHERE NOT EXISTS (
              SELECT 1 FROM state_store
              WHERE `key` = ? AND (expires_at IS NULL OR expires_at > ?)
            )
          SQL
          # MySQL's INSERT...SELECT won't fail on DUPLICATE KEY if WHERE is false
          stmt.execute(key, JSON.generate(value), expires, key, now_f)
          @client.affected_rows > 0
        end

        def clear
          @client.query("DELETE FROM state_store")
        end

        # -- distributed locking --

        def acquire_lock(key, ttl: 10)
          now = Time.now.utc
          expires_at_time = now + ttl
          token = SecureRandom.hex(16)
          now_f = now.strftime("%Y-%m-%d %H:%M:%S.%3N")

          # Clean up expired lock
          @client.prepare("DELETE FROM locks WHERE `key` = ? AND expires_at <= ?").execute(key, now_f)

          result = @client.prepare(<<~SQL).execute(key, expires_at_time.strftime("%Y-%m-%d %H:%M:%S.%3N"), token)
            INSERT INTO locks (`key`, expires_at, token)
            SELECT ?, ?, ?
            WHERE NOT EXISTS (
              SELECT 1 FROM locks WHERE `key` = ?
            )
          SQL
          result = @client.prepare(<<~SQL).execute(key)
            SELECT COUNT(*) AS cnt FROM locks WHERE `key` = ?
          SQL

          # Check if we got the lock
          row = result.first
          return nil unless row && row["cnt"].to_i > 0

          Lock.new(id: key, token: token, expires_at: expires_at_time)
        end

        def release_lock(key, lock)
          @client.prepare("DELETE FROM locks WHERE `key` = ? AND token = ?").execute(key, lock.token)
          @client.affected_rows > 0
        end

        # -- message queues --

        def enqueue(queue, value)
          stmt = @client.prepare(<<~SQL)
            INSERT INTO queues (queue_name, `value`, enqueued_at)
            VALUES (?, ?, ?)
          SQL
          stmt.execute(queue, JSON.generate(value), Time.now.utc.strftime("%Y-%m-%d %H:%M:%S.%3N"))
          id = @client.last_id

          QueueEntry.new(id: id.to_s, value: value, enqueued_at: Time.now)
        end

        def dequeue(queue)
          row = @client.prepare(<<~SQL).execute(queue).first
            SELECT id, `value`, enqueued_at FROM queues
            WHERE queue_name = ?
            ORDER BY id ASC
            LIMIT 1
          SQL
          return nil unless row

          @client.prepare("DELETE FROM queues WHERE id = ?").execute(row["id"])

          QueueEntry.new(
            id: row["id"].to_s,
            value: JSON.parse(row["value"]),
            enqueued_at: Time.parse(row["enqueued_at"])
          )
        end

        def queue_depth(queue)
          result = @client.prepare("SELECT COUNT(*) AS cnt FROM queues WHERE queue_name = ?").execute(queue)
          row = result.first
          row["cnt"]
        end

        # -- ordered lists --

        def list_append(key, value, max_length: nil)
          stmt = @client.prepare("INSERT INTO lists (list_key, `value`) VALUES (?, ?)")
          stmt.execute(key, JSON.generate(value))

          return unless max_length

          @client.prepare(<<~SQL).execute(key, key, max_length)
            DELETE FROM lists WHERE id <= (
              SELECT COALESCE(MIN(id), 0) FROM (
                SELECT id FROM lists
                WHERE list_key = ?
                ORDER BY id DESC
                LIMIT ?
              ) sub
            )
          SQL
        end

        def list_range(key, start = 0, stop = -1)
          rows = if stop == -1
            @client.prepare(<<~SQL).execute(key, start)
              SELECT `value` FROM lists
              WHERE list_key = ?
              ORDER BY id ASC
              LIMIT 18446744073709551615 OFFSET ?
            SQL
          else
            limit = stop - start + 1
            @client.prepare(<<~SQL).execute(key, limit, start)
              SELECT `value` FROM lists
              WHERE list_key = ?
              ORDER BY id ASC
              LIMIT ? OFFSET ?
            SQL
          end
          rows.map { |r| JSON.parse(r["value"]) }
        end

        def list_remove(key, value)
          serialized = JSON.generate(value)
          @client.prepare("DELETE FROM lists WHERE list_key = ? AND `value` = ?").execute(key, serialized)
          @client.affected_rows
        end

        # -- lifecycle --

        def close
          @client&.close
        end

        private

        def migrate
          MIGRATIONS.split(";").each do |sql|
            sql = sql.strip
            @client.query(sql) unless sql.empty?
          end
        rescue => e
          # Tables may already exist with different charset — that's fine
          raise unless e.message.include?("already exists")
        end
      end
    end
  end
end
