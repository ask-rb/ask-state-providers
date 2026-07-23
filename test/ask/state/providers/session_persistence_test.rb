# frozen_string_literal: true

require_relative "../../../test_helper"
require "tempfile"

module Ask
  module State
    module Providers
      class SessionPersistenceTest < Minitest::Test
        def setup
          @tmpfile = Tempfile.new(["test_session", ".db"])
          @adapter = SQLite.new(path: @tmpfile.path)
          @store = SessionPersistence.new(@adapter)
        end

        def teardown
          @adapter.close
          File.unlink(@tmpfile.path) if File.exist?(@tmpfile.path)
        end

        def test_save_and_load
          data = {
            id: "session-1",
            messages: [{ role: "user", content: "Hello" }],
            metadata: { model: "gpt-4o", turn_count: 1 }
          }

          @store.save("session-1", data)
          loaded = @store.load("session-1")

          refute_nil loaded
          assert_equal "session-1", loaded[:id]
          assert_equal 1, loaded[:messages].length
          assert_equal "Hello", loaded[:messages][0][:content]
          assert_equal "gpt-4o", loaded[:metadata][:model]
        end

        def test_load_nonexistent
          assert_nil @store.load("nonexistent")
        end

        def test_save_overwrites
          @store.save("key", { version: 1 })
          @store.save("key", { version: 2 })
          assert_equal 2, @store.load("key")[:version]
        end

        def test_delete
          @store.save("key", { data: "value" })
          @store.delete("key")
          assert_nil @store.load("key")
        end

        def test_works_with_any_adapter
          data = { test: true }
          @store.save("key", data)
          assert_equal data, @store.load("key")
        end

        def test_round_trip_complex_session
          data = {
            id: "complex-session",
            messages: [
              { role: "user", content: "Hi", tool_call_id: nil },
              { role: "assistant", content: "Hello!", tool_call_id: nil },
              { role: "tool", content: "result", tool_call_id: "call_1" }
            ],
            metadata: {
              model: "claude-sonnet-4",
              tools: ["SearchTool", "CalculatorTool"],
              max_turns: 25,
              turn_count: 3,
              created_at: "2026-07-23T00:00:00Z",
              updated_at: "2026-07-23T01:00:00Z"
            }
          }

          @store.save(data[:id], data)
          loaded = @store.load(data[:id])

          assert_equal data[:id], loaded[:id]
          assert_equal data[:messages].length, loaded[:messages].length
          assert_equal data[:metadata][:model], loaded[:metadata][:model]
          assert_equal data[:metadata][:turn_count], loaded[:metadata][:turn_count]
        end
      end
    end
  end
end
