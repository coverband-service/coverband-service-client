# frozen_string_literal: true
require 'socket'

COVERBAND_ORIGINAL_START = ENV['COVERBAND_DISABLE_AUTO_START']
ENV['COVERBAND_DISABLE_AUTO_START'] = 'true'
require 'coverband'
require 'coverband/service/client/version'
require 'securerandom'

module Coverband
  COVERBAND_ENV = ENV['RACK_ENV'] || ENV['RAILS_ENV'] || (defined?(Rails) ? Rails.env : 'unknown')
  COVERBAND_SERVICE_URL = ENV['COVERBAND_URL'] || 'https://coverband.io'
  COVERBAND_TIMEOUT = (COVERBAND_ENV == 'development') ? 5 : 2
  COVERBAND_ENABLE_DEV_MODE = ENV['COVERBAND_ENABLE_DEV_MODE'] || false
  COVERBAND_ENABLE_TEST_MODE = ENV['COVERBAND_ENABLE_TEST_MODE'] || false
  COVERBAND_PROCESS_TYPE = ENV['PROCESS_TYPE'] || 'unknown'
  COVERBAND_REPORT_PERIOD = (ENV['COVERBAND_REPORT_PERIOD'] || 600).to_i

  def self.service_disabled_dev_test_env?
    (COVERBAND_ENV == 'test' && !COVERBAND_ENABLE_TEST_MODE) ||
      (COVERBAND_ENV == 'development' && !COVERBAND_ENABLE_DEV_MODE)
  end

  if service_disabled_dev_test_env?
    def self.report_coverage
      # for now disable coverband reporting in test & dev env by default
      if Coverband.configuration.verbose
        puts "Coverband: disabled for #{COVERBAND_ENV}, set COVERBAND_ENABLE_DEV_MODE or COVERBAND_ENABLE_TEST_MODE to enable" if Coverband.configuration.verbose || COVERBAND_ENABLE_DEV_MODE
      end
    end
  end

    module Adapters
      ###
      # Take Coverband data and store a merged coverage set to the Coverband service
      #
      # NOTES:
      # * uses net/http to avoid any dependencies
      # * currently JSON, but likely better to move to something faster
      ###
      class Service < Base
        attr_reader :coverband_url, :process_type, :runtime_env, :hostname, :pid, :stats

        def initialize(coverband_url, opts = {})
          super()
          @coverband_url = coverband_url
          @process_type = opts.fetch(:process_type) { $PROGRAM_NAME&.split('/')&.last || COVERBAND_PROCESS_TYPE }
          @hostname = opts.fetch(:hostname) { ENV["DYNO"] || Socket.gethostname.force_encoding('utf-8').encode }
          @hostname = @hostname.gsub("'",'').gsub("’",'')
          @runtime_env = opts.fetch(:runtime_env) { COVERBAND_ENV }
          initialize_stats
        end

        def initialize_stats
          return unless ENV['COVERBAND_STATS_KEY']
          return unless defined?(Dogapi::Client)

          @stats = Dogapi::Client.new(ENV['COVERBAND_STATS_KEY'])
          @app_name = defined?(Rails) ? Rails.application.class.module_parent.to_s : "unknown"
        end

        def report_timing(timing)
          return unless @stats

          @stats.emit_point(
            'coverband.save.time',
            timing,
            host: hostname,
            device: "coverband_#{self.class.name.split("::").last}",
            options: {tags: [runtime_env]})
        end

        def logger
          Coverband.configuration.logger
        end

        def clear!
          # TBD
        end

        def clear_file!(filename)
          # TBD
        end

        # TODO: we should support nil to mean not supported
        def size
          0
        end

        def api_key
          ENV['COVERBAND_API_KEY'] || Coverband.configuration.api_key
        end

        ###
        # Fetch coverband coverage via the API
        ###
        def coverage(local_type = nil, opts = {})
          local_type ||= opts.key?(:override_type) ? opts[:override_type] : type
          env_filter = opts.key?(:env_filter) ? opts[:env_filter] : 'production'
          uri = URI("#{coverband_url}/api/coverage?type=#{local_type}&env_filter=#{env_filter}",)
          req = Net::HTTP::Get.new(uri, 'Content-Type' => 'application/json', 'Coverband-Token' => api_key)
          res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
            http.request(req)
          end
          coverage_data = JSON.parse(res.body)
          coverage_data
        rescue StandardError => e
          logger&.error "Coverband: Error while retrieving coverage #{e}" if Coverband.configuration.verbose || COVERBAND_ENABLE_DEV_MODE
        end

        def save_report(report)
          return if report.empty?

          # We set here vs initialize to avoid setting on the primary process vs child processes
          @pid ||= ::Process.pid

          # TODO: do we need dup
          # TODO: remove upstream timestamps, server will track first_seen
          Thread.new do
            data = expand_report(report.dup)
            full_package = {
              collection_type: 'coverage_delta',
              collection_data: {
                tags: {
                  process_type: process_type,
                  app_loading: type == Coverband::EAGER_TYPE,
                  runtime_env: runtime_env,
                  pid: pid,
                  hostname: hostname,
                },
                file_coverage: data
              }
            }

            starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            save_coverage(full_package)
            ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            report_timing((ending - starting))
          end&.join
        end

        def raw_store
          self
        end

        private

        def save_coverage(data)
          if api_key.nil?
            puts "Coverband: Error: no Coverband API key was found!"
            return
          end

          uri = URI("#{coverband_url}/api/collector")
          req = Net::HTTP::Post.new(uri,
                                    'Content-Type' => 'application/json',
                                    'Coverband-Token' => api_key)
          req.body = { remote_uuid: SecureRandom.uuid, data: data }.to_json

          logger&.info "Coverband: saving (#{uri}) #{req.body}" if Coverband.configuration.verbose
          res = Net::HTTP.start(
            uri.hostname,
            uri.port,
            open_timeout: COVERBAND_TIMEOUT,
            read_timeout: COVERBAND_TIMEOUT,
            ssl_timeout: COVERBAND_TIMEOUT,
            use_ssl: uri.scheme == 'https'
            ) do |http|
            http.request(req)
          end
        rescue StandardError => e
          logger&.info "Coverband: Error while saving coverage #{e}" if Coverband.configuration.verbose || COVERBAND_ENABLE_DEV_MODE
        end
      end

      class PersistentService < Service
        attr_reader :http, :stats

        def initialize(coverband_url, opts = {})
          super
          initiate_http
        end

        private

        def initiate_http
          @http = Net::HTTP::Persistent.new name: 'coverband_persistent'
          @http.headers['Content-Type'] = 'application/json'
          @http.headers['Coverband-Token'] = api_key
          @http.open_timeout = COVERBAND_TIMEOUT
          @http.read_timeout = COVERBAND_TIMEOUT
          @http.ssl_timeout = COVERBAND_TIMEOUT
        end

        def save_coverage(data)
          persistent_attempts = 0
          begin
            if api_key.nil?
              puts "Coverband: Error: no Coverband API key was found!"
              return
            end

            post_uri = URI("#{coverband_url}/api/collector")
            post = Net::HTTP::Post.new post_uri.path
            body = { remote_uuid: SecureRandom.uuid, data: data }.to_json
            post.body = body
            logger&.info "Coverband: saving (#{post_uri}) #{body}" if Coverband.configuration.verbose
            res = http.request post_uri, post
          rescue Net::HTTP::Persistent::Error => e
            persistent_attempts += 1
            http.shutdown
            initiate_http
            retry if persistent_attempts < 2
          end
        rescue StandardError => e
          logger&.info "Coverband: Error while saving coverage #{e}" if Coverband.configuration.verbose || COVERBAND_ENABLE_DEV_MODE
        end
      end
    end

  module Service
    module Client
      class Error < StandardError; end
    end
  end
end

###
# TODO: move to a subclass, but the railtie needs to allow setting
# so for now just overiding the class to report via net::http
###
module Coverband
  module Collectors
    class ViewTracker
      def report_views_tracked
        reported_time = Time.now.to_i
        if views_to_record.any?
          relative_views = views_to_record.map! do |view|
            roots.each do |root|
              view = view.gsub(/#{root}/, '')
            end
            view
          end
          save_tracked_views(views: relative_views, reported_time: reported_time)
        end
        self.views_to_record = []
      rescue StandardError => e
        # we don't want to raise errors if Coverband can't reach redis.
        # This is a nice to have not a bring the system down
        logger&.error "Coverband: view_tracker failed to store, error #{e.class.name}" if Coverband.configuration.verbose || COVERBAND_ENABLE_DEV_MODE
      end

      private

      def api_key
        ENV['COVERBAND_API_KEY'] || Coverband.configuration.api_key
      end

      def logger
        Coverband.configuration.logger
      end

      def save_tracked_views(views:, reported_time:)
        uri = URI("#{COVERBAND_SERVICE_URL}/api/collector")
        req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json', 'Coverband-Token' => api_key)
        data = {
          collection_type: 'view_tracker_delta',
          collection_data: {
            tags: {
              runtime_env: COVERBAND_ENV
            },
            collection_time: reported_time,
            tracked_views: views
          }
        }
        # puts "sending #{data}"
        req.body = { remote_uuid: SecureRandom.uuid, data: data }.to_json
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
          http.request(req)
        end
      rescue StandardError => e
        logger&.error "Coverband: Error while saving coverage #{e}" if Coverband.configuration.verbose || COVERBAND_ENABLE_DEV_MODE
      end
    end
  end
end

module Coverband
  class Configuration
    attr_accessor :api_key
  end
end

ENV['COVERBAND_DISABLE_AUTO_START'] = COVERBAND_ORIGINAL_START
Coverband.configure do |config|
  # Use the Service Adapter
  if defined?(Net::HTTP::Persistent)
    config.store = Coverband::Adapters::PersistentService.new(Coverband::COVERBAND_SERVICE_URL)
  else
    config.store = Coverband::Adapters::Service.new(Coverband::COVERBAND_SERVICE_URL)
  end

  # default to tracking views true
  config.track_views = if ENV['COVERBAND_DISABLE_VIEW_TRACKER']
      false
    elsif Coverband.service_disabled_dev_test_env?
      false
    else
      true
    end

  # report every 10m by default
  config.background_reporting_sleep_seconds = Coverband::COVERBAND_ENV == 'production' ? Coverband::COVERBAND_REPORT_PERIOD : 60
  # add a wiggle to avoid service stampede
  config.reporting_wiggle = Coverband::COVERBAND_ENV == 'production' ? 90 : 6

  if Coverband::COVERBAND_ENV == 'test'
    config.background_reporting_enabled = false
  end
end

# NOTE: it is really hard to bypass / overload our config we should fix this in Coverband
# this hopefully detects anyone that has both gems and was trying to configure Coverband themselves.
if File.exist?('./config/coverband.rb')
  puts "Warning: config/coverband.rb found, this overrides coverband service allowing one to setup open source Coverband" if Coverband.configuration.verbose || COVERBAND_ENABLE_DEV_MODE
end

Coverband.configure('./config/coverband_service.rb') if File.exist?('./config/coverband_service.rb')
Coverband.start
require "coverband/utils/railtie" if defined? ::Rails::Railtie
require "coverband/integrations/resque" if defined? ::Resque
