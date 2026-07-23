# frozen_string_literal: true

require "json"
require "securerandom"

module Ask
  module State
    module Providers
      # A distributed key-value store backed by Redis.
      #
      # Implements the full {Ask::State::Adapter} contract:
      # key-value storage, distributed locking, message queues, and ordered
      # lists. Best suited for multi-process or multi-host deployments where
      # shared state is required.
      #
      # @example
      #   store = Ask::State::Providers::Redis.new(url: ENV["REDIS_URL"])
      #   store.set("key", { hello: "world" })
      #   store.get("key")  # => { "hello" => "world" }
      #
      class Redis < ::Ask::State::Adapter
        NAMESPACE = "ask:state"

        # Creates a new Redis-backed state store.
        #
        # @param url [String] Redis URL (redis://...)
        def initialize(url: ENV.fetch("REDIS_URL", "redis://localhost:6379"))
          require "redis"

          @redis = ::Redis.new(url: url)
        end

        # -- key-value --

        def get(key)
          val = @redis.call("GET", prefixed(key))
          val ? JSON.parse(val) : nil
        end

        def set(key, value, ttl: nil)
          args = [prefixed(key), JSON.generate(value)]
          args.concat(["EX", ttl.to_i]) if ttl
          @redis.call("SET", *args)
        end

        def delete(key)
          @redis.call("DEL", prefixed(key))
        end

        def set_if_not_exists(key, value, ttl: nil)
          args = [prefixed(key), JSON.generate(value)]
          args.concat(["EX", ttl.to_i]) if ttl
          @redis.call("SET", *args, "NX") == "OK"
        end

        def clear
          keys = @redis.call("KEYS", "#{NAMESPACE}:*")
          @redis.call("DEL", *keys) if keys.any?
        end

        # -- distributed locking --

        def acquire_lock(key, ttl: 10)
          prefixed_key = prefixed("lock:#{key}")
          token = SecureRandom.hex(16)
          expires_at = Time.now + ttl

          acquired = @redis.call("SET", prefixed_key, token, "NX", "EX", ttl) == "OK"
          acquired ? Lock.new(id: key, token: token, expires_at: expires_at) : nil
        end

        def release_lock(key, lock)
          prefixed_key = prefixed("lock:#{key}")

          # Atomic release: only delete if token matches (Lua script)
          script = <<~LUA
            if redis.call("GET", KEYS[1]) == ARGV[1] then
              return redis.call("DEL", KEYS[1])
            else
              return 0
            end
          LUA

          @redis.call("EVAL", script, [1], [prefixed_key, lock.token]) == 1
        end

        # -- message queues --

        def enqueue(queue, value)
          id = SecureRandom.uuid
          entry = { id: id, value: value, enqueued_at: Time.now.iso8601 }

          @redis.call("RPUSH", prefixed("queue:#{queue}"), JSON.generate(entry))

          QueueEntry.new(id: id, value: value, enqueued_at: Time.now)
        end

        def dequeue(queue)
          val = @redis.call("LPOP", prefixed("queue:#{queue}"))
          return nil unless val

          entry = JSON.parse(val)
          QueueEntry.new(
            id: entry["id"],
            value: entry["value"],
            enqueued_at: Time.parse(entry["enqueued_at"])
          )
        end

        def queue_depth(queue)
          @redis.call("LLEN", prefixed("queue:#{queue}"))
        end

        # -- ordered lists --

        def list_append(key, value, max_length: nil)
          @redis.call("RPUSH", prefixed("list:#{key}"), JSON.generate(value))
          return unless max_length

          # LTRIM keeps only the specified range (negative indices, so -max_length means keep newest max_length)
          @redis.call("LTRIM", prefixed("list:#{key}"), -max_length, -1)
        end

        def list_range(key, start = 0, stop = -1)
          items = @redis.call("LRANGE", prefixed("list:#{key}"), start, stop)
          items.map { |item| JSON.parse(item) }
        end

        def list_remove(key, value)
          serialized = JSON.generate(value)
          @redis.call("LREM", prefixed("list:#{key}"), 0, serialized)
        end

        # -- lifecycle --

        def close
          @redis&.close
        end

        private

        def prefixed(key)
          "#{NAMESPACE}:#{key}"
        end
      end
    end
  end
end
