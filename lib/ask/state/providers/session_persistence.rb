# frozen_string_literal: true

module Ask
  module State
    module Providers
      # Adapts any {Ask::State::Adapter} to the persistence contract
      # expected by {Ask::Agent::Session}.
      #
      # The session expects an object responding to +save(id, data)+,
      # +load(id)+, and +delete(id)+.  This wrapper delegates each call
      # to the equivalent +set+, +get+, and +delete+ methods on a
      # {State::Adapter}.
      #
      # @example
      #   store = Ask::State::Providers::SQLite.new
      #   session = Ask::Agent.new(
      #     "triage",
      #     model: "gpt-4o",
      #     persistence: Ask::State::Providers::SessionPersistence.new(store)
      #   )
      #
      class SessionPersistence
        # @param adapter [Ask::State::Adapter] any state adapter
        def initialize(adapter)
          @adapter = adapter
        end

        # Persist session data under +id+.
        # @param id [String] session identifier
        # @param data [Hash] serializable session state
        def save(id, data)
          @adapter.set(id, data)
        end

        # Load session data for +id+.
        # @param id [String] session identifier
        # @return [Hash, nil] deserialized session state, or +nil+
        def load(id)
          data = @adapter.get(id)
          deep_symbolize_keys(data) if data
        end

        # Remove persisted session data for +id+.
        # @param id [String] session identifier
        def delete(id)
          @adapter.delete(id)
        end
        private

        # Recursively convert string keys to symbol keys in hashes.
        def deep_symbolize_keys(obj)
          case obj
          when Hash
            obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize_keys(v) }
          when Array
            obj.map { |e| deep_symbolize_keys(e) }
          else
            obj
          end
        end
      end
    end
  end
end
