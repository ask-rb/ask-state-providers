# frozen_string_literal: true

require_relative "../../../test_helper"

# fakeredis must be loaded before redis to monkey-patch the connection
require "fakeredis"
require "redis"

module Ask
  module State
    module Providers
      class RedisTest < Minitest::Test
        def setup
          @store = Redis.new(url: "redis://localhost:6379")
          @store.clear
        end

        def teardown
          @store.clear
          @store.close
        end

        # -- key-value --

        class KVTest < RedisTest
          def test_get_set_string
            @store.set("greeting", "hello world")
            assert_equal "hello world", @store.get("greeting")
          end

          def test_get_set_hash
            @store.set("user", { name: "Alice", role: "admin" })
            assert_equal({ "name" => "Alice", "role" => "admin" }, @store.get("user"))
          end

          def test_get_set_array
            data = [1, "two", { three: 3 }]
            @store.set("list", data)
            assert_equal [1, "two", { "three" => 3 }], @store.get("list")
          end

          def test_get_set_integer
            @store.set("count", 42)
            assert_equal 42, @store.get("count")
          end

          def test_get_set_boolean
            @store.set("flag", true)
            assert_equal true, @store.get("flag")
            @store.set("flag", false)
            assert_equal false, @store.get("flag")
          end

          def test_get_missing_key
            assert_nil @store.get("nonexistent")
          end

          def test_set_overwrites_existing
            @store.set("key", "first")
            @store.set("key", "second")
            assert_equal "second", @store.get("key")
          end

          def test_set_with_ttl_not_expired
            @store.set("temp", "value", ttl: 60)
            assert_equal "value", @store.get("temp")
          end

          def test_set_with_ttl_one
            @store.set("temp", "value", ttl: 1)
            assert_equal "value", @store.get("temp")
          end

          def test_set_if_not_exists_creates
            assert @store.set_if_not_exists("unique", "value")
            assert_equal "value", @store.get("unique")
          end

          def test_set_if_not_exists_rejects_existing
            @store.set("existing", "first")
            refute @store.set_if_not_exists("existing", "second")
            assert_equal "first", @store.get("existing")
          end

          def test_delete_removes_key
            @store.set("key", "value")
            @store.delete("key")
            assert_nil @store.get("key")
          end

          def test_delete_nonexistent_key
            @store.delete("nothing")
          end

          def test_clear_removes_all
            @store.set("a", 1)
            @store.set("b", 2)
            @store.clear
            assert_nil @store.get("a")
            assert_nil @store.get("b")
          end

          def test_round_trip_complex_nested
            data = {
              users: [
                { name: "Alice", tags: ["admin", "billing"] },
                { name: "Bob", tags: ["user"] }
              ],
              metadata: { version: 2, migrated_at: "2026-01-01" }
            }
            @store.set("complex", data)
            result = @store.get("complex")
            assert_equal "Alice", result["users"][0]["name"]
            assert_equal ["admin", "billing"], result["users"][0]["tags"]
            assert_equal 2, result["metadata"]["version"]
          end

          def test_special_characters
            @store.set("key with spaces", "value with 中文 and emoji 🎉")
            assert_equal "value with 中文 and emoji 🎉", @store.get("key with spaces")
          end

          def test_empty_string_value
            @store.set("empty", "")
            assert_equal "", @store.get("empty")
          end
        end

        # -- distributed locking --

        class LockingTest < RedisTest
          def test_acquire_and_release_lock
            lock = @store.acquire_lock("resource-1", ttl: 10)
            refute_nil lock
            assert_equal "resource-1", lock.id
            refute_nil lock.token
            refute_nil lock.expires_at

            assert @store.release_lock("resource-1", lock)
          end

          def test_lock_exclusion
            lock1 = @store.acquire_lock("resource-1", ttl: 10)
            refute_nil lock1

            lock2 = @store.acquire_lock("resource-1", ttl: 10)
            assert_nil lock2
          end

          def test_lock_released_can_be_reacquired
            lock1 = @store.acquire_lock("resource-1", ttl: 10)
            @store.release_lock("resource-1", lock1)

            lock2 = @store.acquire_lock("resource-1", ttl: 10)
            refute_nil lock2
          end

          def test_wrong_token_cannot_release
            lock = @store.acquire_lock("resource-1", ttl: 10)
            wrong_lock = Ask::State::Lock.new(id: "resource-1", token: "wrong", expires_at: Time.now + 10)
            refute @store.release_lock("resource-1", wrong_lock)
          end

          def test_double_release_fails
            lock = @store.acquire_lock("resource-1", ttl: 10)
            assert @store.release_lock("resource-1", lock)
            refute @store.release_lock("resource-1", lock)
          end

          def test_independent_locks_dont_conflict
            lock_a = @store.acquire_lock("resource-a", ttl: 10)
            lock_b = @store.acquire_lock("resource-b", ttl: 10)
            refute_nil lock_a
            refute_nil lock_b
          end

          def test_lock_auto_expires
            lock = @store.acquire_lock("resource-1", ttl: 1)
            refute_nil lock
            # Lock should auto-expire after 1 second
            sleep 1.1
            lock2 = @store.acquire_lock("resource-1", ttl: 10)
            refute_nil lock2
          end
        end

        # -- message queues --

        class QueueTest < RedisTest
          def test_enqueue_and_dequeue
            entry = @store.enqueue("tasks", { action: "send_email", to: "user@example.com" })
            refute_nil entry.id
            assert_equal "send_email", entry.value[:action]

            dequeued = @store.dequeue("tasks")
            refute_nil dequeued
            assert_equal entry.id, dequeued.id
            assert_equal "send_email", dequeued.value["action"]
          end

          def test_dequeue_empty_queue
            assert_nil @store.dequeue("empty")
          end

          def test_queue_depth
            assert_equal 0, @store.queue_depth("tasks")
            @store.enqueue("tasks", "first")
            assert_equal 1, @store.queue_depth("tasks")
            @store.enqueue("tasks", "second")
            assert_equal 2, @store.queue_depth("tasks")
            @store.dequeue("tasks")
            assert_equal 1, @store.queue_depth("tasks")
          end

          def test_fifo_order
            3.times { |i| @store.enqueue("fifo", "item-#{i}") }
            assert_equal "item-0", @store.dequeue("fifo").value
            assert_equal "item-1", @store.dequeue("fifo").value
            assert_equal "item-2", @store.dequeue("fifo").value
            assert_nil @store.dequeue("fifo")
          end

          def test_queue_isolation
            @store.enqueue("queue-a", "from-a")
            @store.enqueue("queue-b", "from-b")

            assert_equal "from-a", @store.dequeue("queue-a").value
            assert_nil @store.dequeue("queue-a")
            assert_equal "from-b", @store.dequeue("queue-b").value
          end
        end

        # -- ordered lists --

        class ListTest < RedisTest
          def test_list_append_and_range
            @store.list_append("events", "first")
            @store.list_append("events", "second")
            @store.list_append("events", "third")

            assert_equal ["first", "second", "third"], @store.list_range("events")
          end

          def test_list_range_with_offset
            @store.list_append("list", "a")
            @store.list_append("list", "b")
            @store.list_append("list", "c")
            @store.list_append("list", "d")

            assert_equal ["b", "c"], @store.list_range("list", 1, 2)
          end

          def test_list_range_with_start_only
            @store.list_append("list", "a")
            @store.list_append("list", "b")
            @store.list_append("list", "c")

            assert_equal ["b", "c"], @store.list_range("list", 1)
          end

          def test_list_range_empty
            assert_equal [], @store.list_range("empty")
          end

          def test_list_append_max_length
            5.times { |i| @store.list_append("bounded", i, max_length: 3) }
            assert_equal [2, 3, 4], @store.list_range("bounded")
          end

          def test_list_append_max_length_keeps_newest
            @store.list_append("bounded", "old", max_length: 2)
            @store.list_append("bounded", "middle", max_length: 2)
            @store.list_append("bounded", "new", max_length: 2)
            assert_equal ["middle", "new"], @store.list_range("bounded")
          end

          def test_list_remove
            @store.list_append("list", "a")
            @store.list_append("list", "b")
            @store.list_append("list", "a")
            @store.list_append("list", "c")

            assert_equal 2, @store.list_remove("list", "a")
            assert_equal ["b", "c"], @store.list_range("list")
          end

          def test_list_remove_nonexistent
            @store.list_append("list", "a")
            assert_equal 0, @store.list_remove("list", "nonexistent")
          end

          def test_list_isolation
            @store.list_append("list1", "from-1")
            @store.list_append("list2", "from-2")
            assert_equal ["from-1"], @store.list_range("list1")
            assert_equal ["from-2"], @store.list_range("list2")
          end
        end

        # -- contract conformance --

        class ContractTest < RedisTest
          def test_responds_to_all_adapter_methods
            methods = %i[get set delete set_if_not_exists clear
                         acquire_lock release_lock
                         enqueue dequeue queue_depth
                         list_append list_range list_remove
                         close]
            methods.each { |m| assert_respond_to @store, m }
          end

          def test_namespace_isolation
            store1 = Redis.new(url: "redis://localhost:6379")
            store2 = Redis.new(url: "redis://localhost:6379")

            store1.set("shared", "from-store1")
            assert_equal "from-store1", store1.get("shared")
            # Different instance but same Redis — they share data (by design)
            assert_equal "from-store1", store2.get("shared")

            store1.close
            store2.close
          end
        end
      end
    end
  end
end
