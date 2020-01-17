# frozen_string_literal: true

require "coverband/service/client/version"
require 'securerandom'

module Coverband
    module Adapters
      ###
      # Take Coverband data and store a merged coverage set to the Coverband service
      #
      # NOTES:
      # * uses net/http to avoid any dependencies
      # * currently JSON, but likely better to move to something simpler / faster
      ###
      class Service < Base
        attr_reader :coverband_url, :process_type, :runtime_env, :coverband_id

        def initialize(coverband_url, opts = {})
          super()
          @coverband_url = coverband_url
          @process_type = opts.fetch(:process_type) { 'unknown' }
          @runtime_env = opts.fetch(:runtime_env) { Rails.env }
          @coverband_id = opts.fetch(:coverband_id) { 'coverband-service/coverband_service_demo' }
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
          uri = URI("#{coverband_url}/api/coverage/#{coverband_id}?type=#{local_type}")
          req = Net::HTTP::Get.new(uri, 'Content-Type' => 'application/json', 'Coverband-Token' => 'abcd')
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
          return if report.empty?

          # TODO: do we need dup
          # TODO: remove timestamps, server will track first_seen
          data = expand_report(report.dup)
          full_package = {
            coverband_id: coverband_id,
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
          raise 'not supported'
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
