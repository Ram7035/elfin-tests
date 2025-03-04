# frozen_string_literal: true

require 'mocha/minitest' # mocha makes sure no real http/https requests are made while running the unit tests.
require 'webmock/minitest'
require 'ostruct'
require 'securerandom'

# A module for state maintenance
module ElfinStorage
  # A custom redux pattern implementation/abstraction.
  def self.redux
    # root_reducer argument is just a lambda obtained from combine_reducers.
    create_store = lambda do |root_reducer|
      state = {} # single source of truth for each store.

      store = {
        dispatch: lambda do |*variants|
          # action is a simple hash. Eg: {type: 'COMMON', additional_data: data}
          action = variants[0]
          # reducers_to_call targets particular set of reducers.
          # But its preferred to let the root_reducer/combinations lambda to call every reducer.
          # There won't be any performance issues.
          reducers_to_call = variants[1]

          if reducers_to_call.nil?
            root_reducer.call state, action
          else
            root_reducer.call state, action, reducers_to_call
          end
        end,
        pop_state: lambda do
          clone = state.clone
          state.clear
          clone
        end,
        get_state: lambda do
          state.clone
        end,
        connect: lambda do |map_state_to_result|
          map_state_to_result.call state.clone
        end
      }

      store[:cleanup] = lambda do
        store.clear
        state.clear unless state.empty?
      end

      store
    end

    # combine_reducer's purpose is to create a helper lambda for create_store.
    # And that's it. Its not meant to be used solely.
    # final_reducers argument is just a hash with keys as symbol & values as lambdas.
    combine_reducers = lambda do |final_reducers = Hash.new { |hash, key| hash[key] = {} }|
      # combinations lambda which we return here can be passed to create_store.
      # It gets state & action (eg: {type: 'COMMON'}) as arguments.
      # Then just blindly calls each reducer lambda's by passing the state & action.
      # The reducer will give you the new state.
      combinations = lambda do |state, action, reducers_to_call = nil|
        # An example of how each variable will look like during debugging,
        # final_reducers -> {apple: apple_reducer, orange: orange_reducer}
        # state -> nil
        # On execution of the code, final_reducers.each_key { |key| set_state.call key }
        # state -> {apple: {}, orange: {}}
        # assume {count: 1} is returned by apple_reducer lambda.
        # assume {count: 2} is returned by orange_reducer lambda.
        # Now, state -> {apple: {count: 1}, orange: {count: 2}}

        # This is just a private method to avoid duplicate lines of code.
        set_state = lambda do |key|
          state[key] = {} if state[key].nil?
          updated_state = final_reducers[key].call state[key], action
          state[key] = updated_state unless state.equal? updated_state
        end

        if reducers_to_call.nil?
          # call every reducer that was passed during store creation.
          final_reducers.each_key { |key| set_state.call key }
        else
          reducers_to_call.each { |key| set_state.call key }
        end
      end

      combinations
    end

    [create_store, combine_reducers]
  end

  # some general notes,
  # The type in the action object/hash is just a case statement in a reducer. Like {type: 'COMMON'}
  # state & final_reducers are nothing but a simple closure objects.

  # Some reasoning,
  # The core idea behind this implementation is that a particular action can target any no of reducers.
  # Eg. StubsHelper::COMMON might target almost every reducer in final_reducers hash.
  # Its like a person ordering different parts(state) from different vendors(reducers) and assembling a product.
  # Also you can see that each reducer we have in tests/reducers represents one thing only, like a url/component.

  # Things might get confusing. Just imagine the below flow,
  # final_reducers = {apple: apple_reducer, orange: orange_reducer}
  # root_reducer = combine_reducers.call(final_reducers)
  # store = create_store.call(root_reducer)
  # That's it your store is ready. Don't worry about the state management. closure will do its job.
end

# A module for unit tests wrapping mocha & webmock.
module ElfinTests
  # A redux store extending openStruct object.
  class Store < OpenStruct
    def initialize(hash = nil)
      super hash
      @id = SecureRandom.uuid
    end

    # a method to buy items from the store we choose.
    # Here items are nothing but 3rd party methods/http requests which we are going to mock.
    def score(keys, collector, action = nil)
      dispatch action unless action.nil?

      data = connect(
        lambda do |state|
          state.values_at(*keys)
        end
      )

      yield data if block_given?

      data.each { |v| collector.call v }
    end

    def dispatch(action)
      self[:dispatch].call action
    end

    def fetch
      self[:get_state].call
    end

    def connect(block)
      self[:connect].call block
    end

    def cleanup
      self[:cleanup].call
    end
  end

  private_constant :Store

  # gets all the 3rd party klasses, methods & responses & stubs them.
  def run_stubs
    lambda do |requests|
      requests.each do |klass, methods|
        methods.each do |name, return_value|
          if return_value.is_a?(Hash) && return_value[:error]
            if return_value[:exception]
              klass.any_instance.stubs(name).raises(return_value[:exception], return_value[:error])
            else
              klass.any_instance.stubs(name).raises(return_value[:error])
            end
          elsif return_value.is_a?(Hash) && return_value[:expects]
            expects = return_value[:expects]
            stub = begin
              klass.any_instance.expects(name)
            rescue StandardError => _e
              klass.expects(name)
            end

            if expects[:intercept]
              stub = stub.with do |*args|
                expects[:intercept].call(args.size == 1 ? args[0] : args)
              end
            end

            stub = stub.returns expects[:response]
            if expects[:no_of_times].is_a?(Integer)
              stub.times expects[:no_of_times]
            else
              stub.at_least_once
            end
          else
            begin
              klass.any_instance.stubs(name).returns(return_value)
            rescue StandardError => _e
              klass.stubs(name).returns(return_value)
            end
          end
        end
      end
    end
  end

  # gets all the http/https urls, request & response body & mocks them.
  def run_webmocks
    lambda do |requests|
      requests = requests.values if requests.is_a?(Hash)
      requests.each do |payload|
        params = { headers: { 'Accept' => '*/*' } }

        params = { **params, body: payload[:request] } if %i[post put patch].include?(payload[:type])

        result = WebMock.stub_request(payload[:type], payload[:url])

        wildcard = payload[:wildcard]

        if wildcard
          result.with do |request|
            request&.body&.include?(wildcard)
          end
        elsif !payload[:request].nil?
          result.with(params)
        end

        result.to_return(
          status: payload[:code] || 200,
          body: payload[:response].instance_of?(Proc) ? payload[:response] : payload[:response].to_json,
          headers: {}
        )
      end
    end
  end

  def assert_expectation(payload)
    if payload[:body]
      WebMock.assert_requested(payload[:type], payload[:url],
                               times: payload[:times]) { |req| req.body.include? payload[:body] }
    else
      WebMock.assert_requested payload[:type], payload[:url], times: payload[:times]
    end
  end

  def refute_expectation(payload)
    if payload[:body]
      WebMock.refute_requested(payload[:type], payload[:url]) { |req| req.body.include? payload[:body] }
    else
      WebMock.refute_requested payload[:type], payload[:url]
    end
  end

  def clear_expectation
    WebMock.reset_executed_requests!
  end

  def build_store(reducers)
    create_store, combine_reducers = ElfinStorage.redux

    store = create_store.call(
      combine_reducers.call(
        reducers
      )
    )

    Store.new store
  end
end
