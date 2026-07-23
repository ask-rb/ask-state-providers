# frozen_string_literal: true

# Shared contract tests that every {Ask::State::Adapter} implementation must pass.
#
# Include this module in your provider's test class and set up +@store+ in
# +setup+. Override any method to skip or customize per-backend.
#
# @example
#   class MyAdapterContractTest < Minitest::Test
#     include AdapterContract
#
#     def setup
#       @store = MyAdapter.new
#     end
#   end
#
module AdapterContract
  # Override in provider test to skip tests that don't apply.
  # Return true to skip, false to run.
  def skip_test?(name) = false

  # -- key-value --

  def test_kv_set_and_get
    skip if skip_test?(:test_kv_set_and_get)
    @store.set("k", "hello")
    assert_equal "hello", @store.get("k")
  end

  def test_kv_get_missing
    skip if skip_test?(:test_kv_get_missing)
    assert_nil @store.get("nonexistent")
  end

  def test_kv_overwrite
    skip if skip_test?(:test_kv_overwrite)
    @store.set("k", "first")
    @store.set("k", "second")
    assert_equal "second", @store.get("k")
  end

  def test_kv_delete
    skip if skip_test?(:test_kv_delete)
    @store.set("k", "v")
    @store.delete("k")
    assert_nil @store.get("k")
  end

  def test_kv_ttl_expires
    skip if skip_test?(:test_kv_ttl_expires)
    @store.set("k", "v", ttl: -1)
    assert_nil @store.get("k")
  end

  def test_kv_set_if_not_exists_creates
    skip if skip_test?(:test_kv_set_if_not_exists_creates)
    assert @store.set_if_not_exists("k", "v")
    assert_equal "v", @store.get("k")
  end

  def test_kv_set_if_not_exists_rejects
    skip if skip_test?(:test_kv_set_if_not_exists_rejects)
    @store.set("k", "first")
    refute @store.set_if_not_exists("k", "second")
    assert_equal "first", @store.get("k")
  end

  def test_kv_set_if_not_exists_allows_after_expiry
    skip if skip_test?(:test_kv_set_if_not_exists_allows_after_expiry)
    @store.set("k", "old", ttl: -1)
    assert @store.set_if_not_exists("k", "new")
    assert_equal "new", @store.get("k")
  end

  def test_kv_hash_roundtrip
    skip if skip_test?(:test_kv_hash_roundtrip)
    @store.set("k", { a: 1, b: [2, 3] })
    assert_equal 1, @store.get("k")["a"]
    assert_equal [2, 3], @store.get("k")["b"]
  end

  def test_kv_clear
    skip if skip_test?(:test_kv_clear)
    @store.set("a", 1)
    @store.set("b", 2)
    @store.clear
    assert_nil @store.get("a")
    assert_nil @store.get("b")
  end

  # -- distributed locking --

  def test_lock_acquire_and_release
    skip if skip_test?(:test_lock_acquire_and_release)
    lock = @store.acquire_lock("k", ttl: 10)
    refute_nil lock
    assert_equal "k", lock.id
    refute_nil lock.token
    assert @store.release_lock("k", lock)
  end

  def test_lock_exclusion
    skip if skip_test?(:test_lock_exclusion)
    refute_nil @store.acquire_lock("k", ttl: 10)
    assert_nil @store.acquire_lock("k", ttl: 10)
  end

  def test_lock_release_then_reacquire
    skip if skip_test?(:test_lock_release_then_reacquire)
    lock = @store.acquire_lock("k", ttl: 10)
    @store.release_lock("k", lock)
    refute_nil @store.acquire_lock("k", ttl: 10)
  end

  def test_lock_wrong_token_cannot_release
    skip if skip_test?(:test_lock_wrong_token_cannot_release)
    lock = @store.acquire_lock("k", ttl: 10)
    wrong = Ask::State::Lock.new(id: "k", token: "bad", expires_at: Time.now + 10)
    refute @store.release_lock("k", wrong)
  end

  def test_lock_expired_can_be_acquired
    skip if skip_test?(:test_lock_expired_can_be_acquired)
    refute_nil @store.acquire_lock("k", ttl: -1)
    refute_nil @store.acquire_lock("k", ttl: 10)
  end

  def test_lock_independent_keys
    skip if skip_test?(:test_lock_independent_keys)
    refute_nil @store.acquire_lock("a", ttl: 10)
    refute_nil @store.acquire_lock("b", ttl: 10)
  end

  # -- message queues --

  def test_queue_enqueue_dequeue
    skip if skip_test?(:test_queue_enqueue_dequeue)
    entry = @store.enqueue("q", "hello")
    refute_nil entry.id
    result = @store.dequeue("q")
    refute_nil result
    assert_equal "hello", result.value
  end

  def test_queue_dequeue_empty
    skip if skip_test?(:test_queue_dequeue_empty)
    assert_nil @store.dequeue("empty")
  end

  def test_queue_fifo
    skip if skip_test?(:test_queue_fifo)
    @store.enqueue("q", "a")
    @store.enqueue("q", "b")
    @store.enqueue("q", "c")
    assert_equal "a", @store.dequeue("q").value
    assert_equal "b", @store.dequeue("q").value
    assert_equal "c", @store.dequeue("q").value
    assert_nil @store.dequeue("q")
  end

  def test_queue_depth
    skip if skip_test?(:test_queue_depth)
    assert_equal 0, @store.queue_depth("q")
    @store.enqueue("q", "a")
    assert_equal 1, @store.queue_depth("q")
    @store.enqueue("q", "b")
    assert_equal 2, @store.queue_depth("q")
    @store.dequeue("q")
    assert_equal 1, @store.queue_depth("q")
  end

  def test_queue_isolation
    skip if skip_test?(:test_queue_isolation)
    @store.enqueue("a", "from-a")
    @store.enqueue("b", "from-b")
    assert_equal "from-a", @store.dequeue("a").value
    assert_nil @store.dequeue("a")
    assert_equal "from-b", @store.dequeue("b").value
  end

  # -- ordered lists --

  def test_list_append_and_range
    skip if skip_test?(:test_list_append_and_range)
    @store.list_append("l", "a")
    @store.list_append("l", "b")
    @store.list_append("l", "c")
    assert_equal %w[a b c], @store.list_range("l")
  end

  def test_list_range_empty
    skip if skip_test?(:test_list_range_empty)
    assert_equal [], @store.list_range("empty")
  end

  def test_list_range_offset
    skip if skip_test?(:test_list_range_offset)
    %w[a b c d].each { |v| @store.list_append("l", v) }
    assert_equal %w[b c], @store.list_range("l", 1, 2)
  end

  def test_list_max_length
    skip if skip_test?(:test_list_max_length)
    5.times { |i| @store.list_append("l", i, max_length: 3) }
    assert_equal [2, 3, 4], @store.list_range("l")
  end

  def test_list_remove
    skip if skip_test?(:test_list_remove)
    %w[a b a c].each { |v| @store.list_append("l", v) }
    assert_equal 2, @store.list_remove("l", "a")
    assert_equal %w[b c], @store.list_range("l")
  end

  def test_list_isolation
    skip if skip_test?(:test_list_isolation)
    @store.list_append("a", "from-a")
    @store.list_append("b", "from-b")
    assert_equal ["from-a"], @store.list_range("a")
    assert_equal ["from-b"], @store.list_range("b")
  end

  # -- conformance --

  def test_responds_to_all_primitives
    skip if skip_test?(:test_responds_to_all_primitives)
    methods = %i[get set delete set_if_not_exists clear
                 acquire_lock release_lock
                 enqueue dequeue queue_depth
                 list_append list_range list_remove
                 close]
    methods.each { |m| assert_respond_to @store, m }
  end
end
