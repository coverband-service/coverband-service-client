# frozen_string_literal: true

require 'coverband/service/client/version'
require 'securerandom'

COVERBAND_ENV = ENV['RACK_ENV'] || ENV['RAILS_ENV'] || (defined?(Rails) ? Rails.env : 'unknown')
COVERBAND_SERVICE_URL = ENV['COVERBAND_URL'] ||
  ((COVERBAND_ENV == 'development') ? 'http://127.0.0.1:3456' : 'https://coverband-service.herokuapp.com')

module Coverband

  if COVERBAND_ENV == 'test' && !ENV['COVERBAND_ENABLE_TEST_MODE']
    def self.report_coverage
      # for now disable coverband reporting in test env by default
    end
  end

    module Adapters
      ###
      # Take Coverband data and store a merged coverage set to the Coverband service
      #
      # NOTES:
      # * uses net/http to avoid any dependencies
      # * currently JSON, but likely better to move to something simpler / faster
      ###
      class Service < Base
        attr_reader :coverband_url, :process_type, :runtime_env

        def initialize(coverband_url, opts = {})
          super()
          @coverband_url = coverband_url
          @process_type = opts.fetch(:process_type) { 'unknown' }
          @runtime_env = opts.fetch(:runtime_env) { COVERBAND_ENV }
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

        # TODO: no longer get by type just get both reports in a single request
        def coverage(local_type = nil, opts = {})
          local_type ||= opts.key?(:override_type) ? opts[:override_type] : type
          uri = URI("#{coverband_url}/api/coverage/#{ENV['COVERBAND_ID']}?type=#{local_type}")
          req = Net::HTTP::Get.new(uri, 'Content-Type' => 'application/json', 'Coverband-Token' => ENV['COVERBAND_API_KEY'])
          res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
            http.request(req)
          end
          coverage_data = JSON.parse(res.body)
          # puts "coverage data: "
          # puts coverage_data
          coverage_data
        rescue StandardError => e
          puts "Coverband: Error while retrieving coverage #{e}"
        end

        def save_report(report)
          #puts caller.join(',')
          return if report.empty?

          # TODO: do we need dup
          # TODO: remove timestamps, server will track first_seen
          data = expand_report(report.dup)
          full_package = {
            collection_type: 'coverage_delta',
            collection_data: {
              tags: {
                process_type: process_type,
                app_loading: type == Coverband::EAGER_TYPE,
                runtime_env: runtime_env
              },
              file_coverage: data
            }
          }
          save_coverage(full_package)
        end

        def raw_store
          self
        end

        private

        def save_coverage(data)
          uri = URI("#{coverband_url}/api/collector")
          req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json', 'Coverband-Token' => ENV['COVERBAND_API_KEY'])
          puts "sending #{data}"
          req.body = { remote_uuid: SecureRandom.uuid, data: data }.to_json
          res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
            http.request(req)
          end
        rescue StandardError => e
          puts "Coverband: Error while saving coverage #{e}"
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
        logger&.error "Coverband: view_tracker failed to store, error #{e.class.name}"
      end

      private

      def save_tracked_views(views:, reported_time:)
        uri = URI("#{COVERBAND_SERVICE_URL}/api/collector")
        req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json', 'Coverband-Token' => ENV['COVERBAND_API_KEY'])
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
        puts "sending #{data}"
        req.body = { remote_uuid: SecureRandom.uuid, data: data }.to_json
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
          http.request(req)
        end
      rescue StandardError => e
        puts "Coverband: Error while saving coverage #{e}"
      end
    end
  end
end

Coverband.configure do |config|
  # toggle store type

  # redis_url = ENV['REDIS_URL']
  # Normal Coverband Setup
  # config.store = Coverband::Adapters::HashRedisStore.new(Redis.new(url: redis_url))

  # Use The Test Service Adapter
  config.store = Coverband::Adapters::Service.new(COVERBAND_SERVICE_URL)

  # default to tracking views true
  config.track_views = ENV['COVERBAND_ENABLE_VIEW_TRACKER'] ? true : false

  if COVERBAND_ENV == 'test'
    config.background_reporting_enabled = false
  end
end
