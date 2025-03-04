# frozen_string_literal: true

$VERBOSE = nil

if ENV['COV_ENV'] == 'test'
  require 'simplecov'
  require 'simplecov-json'
  SimpleCov.formatter = SimpleCov::Formatter::JSONFormatter
  SimpleCov.start
end

ENV['APP_ENV'] = 'test'
ENV['ENV'] = 'test'

# Generated purely for unit tests.
ENV['AES_KEY'] = '0CC175B9C0F1B6A831C399E269772661CEC520EA51EA0A47E87295FA3245A605'
ENV['AES_IV'] = '4FA92C5873672E20FB163A0BCB2BB4A4'

TEST_ACC_NO = '1234567'
TEST_EXCEPTION = 'Custom test exception'

require 'minitest/autorun'
require 'minitest/hooks/default'
require 'minitest/reporters'
require 'rack/test'
require 'shoulda/context'

require 'tests/elfin_tests'

require 'tests/mocks/logger_mock'

require 'tests/helpers/sql_helper'
require 'tests/helpers/service_helper'
require 'tests/helpers/stubs_helper'
require 'tests/helpers/util_helper'

require 'tests/test_utilities'

require 'tests/operations/ops'

# This check is to not interfere with Rubymine's default reporter during dev purposes.
unless ENV['RM_INFO']
  Minitest::Reporters.use!(
    [Minitest::Reporters::SpecReporter.new(color: true),
     Minitest::Reporters::MeanTimeReporter.new(color: true)]
  )
end

# A common test klass for channel-manager implementing minitest.
class AppTests < Minitest::Test
  include Minitest::Hooks
  include Rack::Test::Methods
  include ElfinTests
  include Ops

  attr_accessor :common_stubs, :cache, :expected_res_code, :run_dependencies_only

  # run all the pre-requisites before executing tests of any klass.
  def before_all
    super
    @common_stubs = build_store(
      { api_server: api_server_reducer,
        oauth: oauth_reducer,
        cms: cms_reducer }
    )
  end

  def app
    # App class
  end

  def setup
    super
    common_stubs.score %i[api_server statsd], run_stubs
    common_stubs.score %i[oauth settings], run_webmocks
    self.expected_res_code ||= 200
    self.run_dependencies_only = false
  end

  def expect(response_code)
    self.expected_res_code = response_code
    self
  end

  def reset_expected_code
    self.expected_res_code = 200
  end

  # do the cleanup stuffs.
  def after_all
    [common_stubs, cache].each do |store|
      store&.cleanup
    end

    tables_to_clean = ObjectSpace.each_object(Sequel::Model).map { |x| x.class.name }.uniq
    tables_to_clean.each do |table_name|
      klass = Object.const_get(table_name)

      if table_name.downcase == 'table_name'
        klass.all do |asset|
          klass.where(public_id: asset[:public_id]).destroy
        end
        next
      end

      klass.all(&:destroy)
    end

    super
  end
end

# What is a store & how it works?

# store in real-world have space for storage, then stocks items based on requirements &
# then we can buy the items we want from the store.
# build_store provides a store object which is an openStruct extension,
# that gives back a :state property & methods like :dispatch & :connect.
# Here, :state is the real-world equivalent to the storage.
# :dispatch is the real-world equivalent to stocking the items.
# :connect is how we buy what we want from the stocked items.

# The store is built based on the reducers. Reducers are explained in tests/elfin_tests.rb.

# Now back to the stores,
# In the code, you can see four types of stores, 1.) common_stubs, 2.) cache, 3.) stubs_store, 4.) mocks_store

# common_stubs -> a store that keeps track of the commonly used 3rd party/unwanted methods we need to stub.
# cache        -> a store that keeps track of whatever data that can be re-used.
# Its been used very minimally but it can be used extensively if needed.
# stubs_store  -> a store that keeps track of the test dependent 3rd party/unwanted methods we need to stub.
# mocks_store  -> a store that keeps track of the test dependent external http/https requests we need to mock.

# Difference between stubs & mocks,
# stubs - dummy execution for 3rd party sdk methods.
# mocks - dummy execution for http/https requests.
