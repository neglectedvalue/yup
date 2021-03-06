require 'uri'
require 'rubygems'
require 'eventmachine'
require 'logger'
require 'yajl'
require 'tmpdir'

require 'yup/version'
require 'yup/request_forwarder'
require 'yup/request_handler'
require 'yup/state'

module Yup
  @@resend_delay = 60.0
  def self.resend_delay; @@resend_delay end
  def self.resend_delay=(seconds); @@resend_delay = seconds end

  @@watermark = 100
  def self.watermark; @@watermark end
  def self.watermark=(seconds); @@watermark = seconds end

  @@logger = Logger.new(STDOUT)
  def self.logger; @@logger end
  def self.logger=(logger); @@logger = logger end

  @@retry_unless_2xx = false
  def self.retry_unless_2xx; @@retry_unless_2xx end
  def self.retry_unless_2xx=(bool); @@retry_unless_2xx = bool end

  def self.run(config)
    host        = config[:listen_host] || 'localhost'
    port        = config[:listen_port] || 8080
    status_code = config[:status_code] || 200
    forward_to  = config[:forward_to]
    timeout     = config[:timeout] || 60

    EM.run do
      EM.start_server(host, port, RequestHandler, forward_to, status_code, nil, timeout)
      logger.info { "listening on #{host}:#{port}" }
    end
  end

  def self.run_with_state(config)
    case State.queue_type(config[:persistent])
    when :bdb
      self.run_with_bdb(config)
    when :redis
      self.run_with_redis(config)
    else
      abort "Unknown scheme of persistent queue."
    end
  end

  def self.run_with_bdb(config)
    require 'yup/state/bdb'

    host        = config[:listen_host] || 'localhost'
    port        = config[:listen_port] || 8080
    status_code = config[:status_code] || 200
    forward_to  = config[:forward_to]
    dbpath      = config[:persistent]
    timeout     = config[:timeout] || 60
    feedback_channel = File.join(Dir.tmpdir, "yupd-#{$$}-feedback")
    state            = State::BDB.new(dbpath, forward_to, feedback_channel)

    pid = Process.fork do
      State::BDB::RequestForwarder.new(state, forward_to, timeout).run_loop
    end

    if pid
      db_closer = proc do
        Yup.logger.info { "Terminating consumer #{$$}" }
        Process.kill("KILL", pid)
        state.dispose()
        exit 0
      end
      Signal.trap("TERM", &db_closer)
      Signal.trap("INT", &db_closer)
    end

    EM.run do
      EM.start_unix_domain_server(feedback_channel, State::BDB::FeedbackHandler, state)
      logger.info { "Feedback through #{feedback_channel}" }

      EM.start_server(host, port, RequestHandler, forward_to, status_code, state, timeout)
      logger.info { "Listening on #{host}:#{port}" }
    end
  end

  def self.run_with_redis(config)
    require 'yup/state/redis'

    host        = config[:listen_host] || 'localhost'
    port        = config[:listen_port] || 8080
    status_code = config[:status_code] || 200
    forward_to  = config[:forward_to]
    dbpath      = config[:persistent]
    timeout     = config[:timeout] || 60
    state       = State::Redis.new(dbpath, forward_to)

    pid = Process.fork do
      State::Redis::RequestForwarder.new(state, forward_to, timeout).run_loop
    end

    if pid
      db_closer = proc do
        Yup.logger.info { "Terminating consumer #{$$}" }
        Process.kill("KILL", pid)
        state.dispose()
        exit 0
      end
      Signal.trap("TERM", &db_closer)
      Signal.trap("INT", &db_closer)
    end

    EM.run do
      EM.start_server(host, port, RequestHandler, forward_to, status_code, state, timeout)
      logger.info { "Listening on #{host}:#{port}" }
    end
  end
end
