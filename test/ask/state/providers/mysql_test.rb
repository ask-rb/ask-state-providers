# frozen_string_literal: true

require_relative "../../../test_helper"

module Ask
  module State
    module Providers
      class MySQLTest < Minitest::Test
        SKIP = ENV.fetch("MYSQL_URL", "").empty?

        def setup
          skip "Set MYSQL_URL to test MySQL provider" if self.class::SKIP
          @store = MySQL.new(url: ENV["MYSQL_URL"])
          @store.clear
        end

        def teardown
          return if self.class::SKIP
          @store.clear
          @store.close
        end

        # -- key-value --

        class KVTest < MySQLTest
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

          def test_get_missing_key
            assert_nil @store.get("nonexistent")
          end

          def test_set_overwrites_existing
            @store.set("key", "first")
            @store.set("key", "second")
            assert_equal "second", @store.get("key")
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
                { name: "Alice", tags: ["admin"] },
                { name: "Bob", tags: ["user"] }
              ]
            }
            @store.set("complex", data)
            result = @store.get("complex")
            assert_equal "Alice", result["users"][0]["name"]
          end

          def test_empty_string_value
            @store.set("empty", "")
            assert_equal "", @store.get("empty")
          end
        end

        # -- distributed locking --

        class LockingTest < MySQLTest
          def test_acquire_and_release_lock
            lock = @store.acquire_lock("resource-1", ttl: 10)
            refute_nil lock
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
        end

        # -- message queues --

        class QueueTest < MySQLTest
          def test_enqueue_and_dequeue
            entry = @store.enqueue("tasks", { action: "process" })
            refute_nil entry.id
            dequeued = @store.dequeue("tasks")
            refute_nil dequeued
            assert_equal "process", dequeued.value["action"]
          end

          def test_fifo_order
            3.times { |i| @store.enqueue("fifo", "item-#{i}") }
            assert_equal "item-0", @store.dequeue("fifo").value
            assert_equal "item-1", @store.dequeue("fifo").value
            assert_equal "item-2", @store.dequeue("fifo").value
            assert_nil @store.dequeue("fifo")
          end

          def test_queue_depth
            assert_equal 0, @store.queue_depth("tasks")
            @store.enqueue("tasks", "first")
            assert_equal 1, @store.queue_depth("tasks")
          end
        end

        # -- ordered lists --

        class ListTest < MySQLTest
          def test_list_append_and_range
            @store.list_append("events", "a")
            @store.list_append("events", "b")
            assert_equal ["a", "b"], @store.list_range("events")
          end

          def test_list_append_max_length
            5.times { |i| @store.list_append("bounded", i, max_length: 3) }
            assert_equal [2, 3, 4], @store.list_range("bounded")
          end

          def test_list_remove
            @store.list_append("list", "a")
            @store.list_append("list", "b")
            @store.list_append("list", "a")
            assert_equal 2, @store.list_remove("list", "a")
            assert_equal ["b"], @store.list_range("list")
          end

          def test_list_range_empty
            assert_equal [], @store.list_range("empty")
          end
        end

        # -- contract conformance --

        class ContractTest < MySQLTest
          def test_responds_to_all_adapter_methods
            methods = %i[get set delete set_if_not_exists clear
                         acquire_lock release_lock
                         enqueue dequeue queue_depth
                         list_append list_range list_remove
                         close]
            methods.each { |m| assert_respond_to @store, m }
          end
        end
      end
    end
  end
end
