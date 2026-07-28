# frozen_string_literal: true

require_relative "../../test_helper"

class MemoryStateTest < Minitest::Test
  def setup
    @store = Ask::State::Memory.new
  end

  def teardown
    @store.close
  end

  # -- Key-value --

  def test_get_set
    @store.set("name", "Alice")
    assert_equal "Alice", @store.get("name")
  end

  def test_get_missing
    assert_nil @store.get("nonexistent")
  end

  def test_overwrite
    @store.set("key", "value1")
    @store.set("key", "value2")
    assert_equal "value2", @store.get("key")
  end

  def test_delete
    @store.set("key", "value")
    @store.delete("key")
    assert_nil @store.get("key")
  end

  def test_delete_missing
    @store.delete("nonexistent")
  end

  def test_set_if_not_exists
    assert @store.set_if_not_exists("key", "first")
    refute @store.set_if_not_exists("key", "second")
    assert_equal "first", @store.get("key")
  end

  def test_exists
    @store.set("key", "value")
    assert @store.exists?("key")
    refute @store.exists?("other")
  end

  def test_clear
    @store.set("a", 1)
    @store.set("b", 2)
    @store.clear
    assert_nil @store.get("a")
    assert_nil @store.get("b")
  end

  def test_keys
    @store.set("x", 1)
    @store.set("y", 2)
    assert_includes @store.keys, "x"
    assert_includes @store.keys, "y"
  end

  def test_ttl_expiration
    @store.set("ephemeral", "value", ttl: 0)
    sleep 0.01
    assert_nil @store.get("ephemeral")
  end

  # -- Locking --

  def test_acquire_and_release_lock
    lock = @store.acquire_lock("resource", ttl: 10)
    assert lock
    assert @store.release_lock("resource", lock)
  end

  def test_lock_prevents_concurrent_access
    lock1 = @store.acquire_lock("resource", ttl: 10)
    lock2 = @store.acquire_lock("resource", ttl: 10)
    assert lock1
    assert_nil lock2
  end

  def test_release_wrong_token_fails
    lock = @store.acquire_lock("resource", ttl: 10)
    wrong = Ask::State::Lock.new(id: "resource", token: "wrong", expires_at: Time.now + 10)
    refute @store.release_lock("resource", wrong)
  end

  # -- Queues --

  def test_enqueue_dequeue
    @store.enqueue("tasks", "job1")
    @store.enqueue("tasks", "job2")
    assert_equal "job1", @store.dequeue("tasks").value
    assert_equal "job2", @store.dequeue("tasks").value
    assert_nil @store.dequeue("tasks")
  end

  def test_queue_depth
    @store.enqueue("q", "a")
    @store.enqueue("q", "b")
    assert_equal 2, @store.queue_depth("q")
  end

  # -- Lists --

  def test_list_append_and_range
    @store.list_append("logs", "entry1")
    @store.list_append("logs", "entry2")
    assert_equal ["entry1", "entry2"], @store.list_range("logs")
  end

  def test_list_remove
    @store.list_append("items", "a")
    @store.list_append("items", "b")
    @store.list_append("items", "a")
    @store.list_remove("items", "a")
    assert_equal ["b"], @store.list_range("items")
  end

  # -- Thread safety --

  def test_concurrent_access
    threads = 10.times.map do |i|
      Thread.new do
        @store.set("counter", i)
      end
    end
    threads.each(&:join)
    # Just verify no exception was raised
    assert true
  end
end
