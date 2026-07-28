# frozen_string_literal: true

require "ask"
require "ask/state"

# Load the in-memory state backend (default adapter, previously in ask-core)
require_relative "ask/state/memory"

module Ask
  module State
    module Providers
      autoload :SQLite,    "ask/state/providers/sqlite"
      autoload :Redis,     "ask/state/providers/redis"
      autoload :Postgres,  "ask/state/providers/postgres"
      autoload :MySQL,     "ask/state/providers/mysql"
    end
  end
end
