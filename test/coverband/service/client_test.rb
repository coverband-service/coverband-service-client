require "test_helper"

class Coverband::Service::ClientTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Coverband::Service::Client::VERSION
  end

  def test_it_does_something_useful
    assert false
  end
end
