class TestSensu < MiniTest::Unit::TestCase
  include EM::Ventually
  EM::Ventually.total_default = 1.5

  def setup
    @options = {:config_file => File.join(File.dirname(__FILE__), 'config.json')}
    config = Sensu::Config.new(@options)
    @settings = config.settings
  end

  def test_read_config_file
    config = Sensu::Config.new(@options)
    settings = config.settings
    eventually(true, :total => 0.5) { settings.key?('client') }
  end

  def test_cli_arguments
    options = Sensu::Config.read_arguments(['-w', '-c', @options[:config_file]])
    eventually({:worker => true, :config_file => @options[:config_file]}, :total => 0.5) { options }
  end

  def test_keepalives
    server = Sensu::Server.new(@options)
    client = Sensu::Client.new(@options)
    server.setup_redis
    server.setup_amqp
    server.setup_keepalives
    client.setup_amqp
    client.setup_keepalives
    test_client = ''
    EM.add_timer(1) do
      server.redis.get('client:' + @settings.client.name).callback do |client_json|
        test_client = JSON.parse(client_json).reject { |key, value| key == 'timestamp' }
      end
    end
    eventually(@settings['client']) { test_client }
  end

  def test_handlers
    server = Sensu::Server.new(@options)
    event = Hashie::Mash.new({
      :client => @settings.client,
      :check => {
        :name => 'test_handlers',
        :handler => 'default',
        :issued => Time.now.to_i,
        :status => 1,
        :output => 'WARNING\n',
        :flapping => false
      },
      :occurrences => 1,
      :action => 'create'
    })
    server.handle_event(event)
    eventually(true) do
      JSON.parse(File.open('/tmp/sensu_test_handlers', 'rb').read) == event.to_hash
    end
  end

  def test_publish_subscribe
    server = Sensu::Server.new(@options)
    client = Sensu::Client.new(@options)
    server.setup_redis
    server.setup_amqp
    server.redis.flushall
    server.setup_keepalives
    server.setup_results
    client.setup_amqp
    client.setup_keepalives
    client.setup_subscriptions
    server.setup_publisher(:test => true)
    client_events = Hash.new
    EM.add_timer(1) do
      server.redis.hgetall('events:' + @settings.client.name).callback do |events|
        client_events = Hash[*events]
        client_events.each do |key, value|
          client_events[key] = JSON.parse(value).symbolize_keys
        end
      end
    end
    parallel do
      @settings.checks.each_with_index do |(name, details), index|
        expected_result = {
          :status => index + 1,
          :output => @settings.client.name + "\n",
          :flapping => false,
          :occurrences => 1
        }
        eventually(expected_result) { client_events[name] }
      end
    end
  end

  def test_client_socket
    server = Sensu::Server.new(@options)
    client = Sensu::Client.new(@options)
    server.setup_redis
    server.setup_amqp
    server.redis.flushall
    server.setup_keepalives
    client.setup_amqp
    client.setup_keepalives
    server.setup_results
    client.setup_socket
    external_source = proc do
      socket = TCPSocket.open('127.0.0.1', 3030)
      socket.write('{"name": "external", "status": 1, "output": "test"}')
    end
    EM.defer(external_source)
    client_events = Hash.new
    EM.add_timer(1) do
      server.redis.hgetall('events:' + @settings.client.name).callback do |events|
        client_events = Hash[*events]
      end
    end
    eventually(true) { client_events.include?('external') }
  end
end
