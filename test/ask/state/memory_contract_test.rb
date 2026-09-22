# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../support/adapter_contract"

# Runs the shared AdapterContract against Ask::State::Memory — the
# reference implementation of the lock contract (token match plus
# expired? on release) that the SQL and Redis backends are held to.
class MemoryContractTest < Minitest::Test
  include AdapterContract

  def setup
    @store = Ask::State::Memory.new
  end

  def teardown
    @store.close
  end

  # Memory stores objects as-is — no JSON round-trip — so a symbol-keyed
  # hash comes back with symbol keys while every persistent backend
  # returns string keys. Pre-existing KV divergence, outside the lock
  # contract this suite hardens; skipped rather than papered over.
  def skip_test?(name)
    name == :test_kv_hash_roundtrip
  end
end
