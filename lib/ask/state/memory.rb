# frozen_string_literal: true

require "securerandom"

module Ask
  module State
    # In-process state backend backed by a Hash.
    # All operations are thread-safe via a Mutex.
    # Data is not persisted — lost on process exit.
    #
    # Available automatically when using +ask-state-providers+.
    # For lightweight use without the full providers gem, see
    # {Ask::State::Adapter} for the abstract contract.
    class Memory < Adapter
      def initialize
        @data = {}
        @locks = {}
        @queues = {}
        @lists = {}
        @mutex = Mutex.new
      end

      # -- key-value --

      def get(key)
        @mutex.synchronize do
          expiry = @data[key]&.dig(:expires_at)
          return nil if expiry && Time.now >= expiry

          @data[key]&.dig(:value)
        end
      end

      def set(key, value, ttl: nil)
        @mutex.synchronize do
          @data[key] = {
            value: value,
            expires_at: ttl ? Time.now + ttl : nil
          }
        end
      end

      def delete(key)
        @mutex.synchronize do
          @data.delete(key)
          # delete removes everything under the key, including ordered
          # lists (consumers store event feeds and queues as lists).
          @lists.delete(key)
          @queues.delete(key)
        end
      end

      def set_if_not_exists(key, value, ttl: nil)
        @mutex.synchronize do
          if @data.key?(key)
            expiry = @data[key][:expires_at]
            return false if expiry.nil? || Time.now < expiry
            @data.delete(key)
          end

          @data[key] = {
            value: value,
            expires_at: ttl ? Time.now + ttl : nil
          }
          true
        end
      end

      def clear
        @mutex.synchronize do
          @data.clear
          @locks.clear
          @queues.clear
          @lists.clear
        end
      end

      def exists?(key)
        @mutex.synchronize do
          expiry = @data[key]&.dig(:expires_at)
          return false if expiry && Time.now >= expiry
          @data.key?(key)
        end
      end

      def keys(pattern: nil)
        @mutex.synchronize do
          active = @data.select do |_k, v|
            expiry = v[:expires_at]
            expiry.nil? || Time.now < expiry
          end

          keys = active.keys.map(&:to_s)
          return keys unless pattern

          regex = self.class.glob_to_regex(pattern)
          keys.select { |k| k.match?(regex) }
        end
      end

      # -- locking --

      def acquire_lock(key, ttl: 10)
        @mutex.synchronize do
          existing = @locks[key]
          if existing.nil? || existing.expired?
            lock = Lock.new(
              id: key,
              token: SecureRandom.hex(16),
              expires_at: Time.now + ttl
            )
            @locks[key] = lock
            lock
          end
        end
      end

      def release_lock(key, lock)
        @mutex.synchronize do
          current = @locks[key]
          if current && current.token == lock.token && !current.expired?
            @locks.delete(key)
            true
          else
            false
          end
        end
      end

      # -- queues --

      def enqueue(queue, value)
        @mutex.synchronize do
          @queues[queue] ||= []
          entry = QueueEntry.new(
            id: SecureRandom.uuid,
            value: value,
            enqueued_at: Time.now
          )
          @queues[queue] << entry
          entry
        end
      end

      def dequeue(queue)
        @mutex.synchronize do
          q = @queues[queue]
          return nil unless q&.any?
          q.shift
        end
      end

      def queue_depth(queue)
        @mutex.synchronize do
          (@queues[queue] || []).length
        end
      end

      # -- lists --

      def list_append(key, value, max_length: nil)
        @mutex.synchronize do
          @lists[key] ||= []
          @lists[key] << value
          @lists[key].shift if max_length && @lists[key].length > max_length
        end
      end

      def list_range(key, start = 0, stop = -1)
        @mutex.synchronize do
          list = @lists[key] || []
          return list if start == 0 && stop == -1
          stop = list.length - 1 if stop == -1 || stop >= list.length
          return [] if start > stop
          list[start..stop] || []
        end
      end

      def list_remove(key, value)
        @mutex.synchronize do
          list = @lists[key]
          return 0 unless list
          before = list.length
          list.delete(value)
          before - list.length
        end
      end

      # -- lifecycle --

      # Idempotent setup. No-op for in-memory — data is lost on process exit.
      def setup!
        true
      end

      def close
        @mutex.synchronize do
          @data.clear
          @locks.clear
          @queues.clear
          @lists.clear
        end
      end

      private

      def glob_to_regex(pattern)
        self.class.glob_to_regex(pattern)
      end
    end
  end
end
