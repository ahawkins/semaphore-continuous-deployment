require 'bundler/setup'

ENV['RACK_ENV'] = 'test'

require 'minitest/autorun'
require 'rack/test'

require_relative '../src/app'

class AppTest < MiniTest::Test
  include Rack::Test::Methods

  def app
    App
  end

  def test_hello_world
    get '/'
    assert last_response.ok?
    assert_equal 'Hello World', last_response.body
  end

  def test_ping
    get '/ping'
    assert last_response.ok?
  end
end
