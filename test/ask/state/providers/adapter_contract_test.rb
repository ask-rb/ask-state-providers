# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../support/adapter_contract"
require "tempfile"

# Runs the shared AdapterContract against every available provider.
# Providers that require a database server (Postgres, MySQL) are only
# tested when their connection URL is set.

module Ask
  module State
    module Providers
      class SQLiteContractTest < Minitest::Test
        include AdapterContract

        def setup
          @tmpfile = Tempfile.new(["contract", ".db"])
          @path = @tmpfile.path
          @tmpfile.close
          @store = SQLite.new(path: @path)
        end

        def teardown
          @store.close
          File.unlink(@path) if File.exist?(@path)
        end
      end

      class RedisContractTest < Minitest::Test
        include AdapterContract

        def setup
          @store = Redis.new(url: "redis://localhost:6379")
          @store.clear
        end

        def teardown
          @store.clear
          @store.close
        end

        # Redis rejects negative/zero TTL values, so tests that rely on
        # immediate expiry must be skipped for this backend.
        def skip_test?(name)
          %i[test_kv_ttl_expires
             test_kv_set_if_not_exists_allows_after_expiry
             test_lock_expired_can_be_acquired].include?(name)
        end
      end

      class PostgresContractTest < Minitest::Test
        include AdapterContract

        def setup
          skip "Set DATABASE_URL to test PostgreSQL" if ENV["DATABASE_URL"].to_s.empty?
          @store = Postgres.new(url: ENV["DATABASE_URL"])
          @store.clear
        end

        def teardown
          return unless defined?(@store)
          @store.clear
          @store.close
        end
      end

      class MySQLContractTest < Minitest::Test
        include AdapterContract

        def setup
          skip "Set MYSQL_URL to test MySQL" if ENV["MYSQL_URL"].to_s.empty?
          @store = MySQL.new(url: ENV["MYSQL_URL"])
          @store.clear
        end

        def teardown
          return unless defined?(@store)
          @store.clear
          @store.close
        end
      end
    end
  end
end
