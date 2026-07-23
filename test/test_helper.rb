# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ask-state-providers"

require "minitest/autorun"
require "mocha/minitest"
require "tmpdir"
require "fileutils"

module TestHelpers
  # Returns a path to a fixture file. Creates a temp copy so tests can safely
  # modify or delete without affecting the original fixture.
  def fixture_path(name)
    File.join(File.expand_path("fixtures", __dir__), name)
  end

  # Returns the contents of a fixture file.
  def fixture(name)
    File.read(fixture_path(name))
  end
end

Minitest::Test.include(TestHelpers)
