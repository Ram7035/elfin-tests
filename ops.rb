# frozen_string_literal: true

require 'tests/reducers/stubs_reducers'
require 'tests/reducers/webmocks_reducers'
require 'tests/reducers/cache_reducers'

# parent module for all the api operations.
module Ops
  def load_test_dependencies(action, stubs: nil, mocks: nil)
    unless stubs.nil?
      stubs_store = build_store(stubs)
      stubs_store.score stubs.keys, run_stubs, action
    end

    return if mocks.nil?

    mocks_store = build_store(mocks)
    mocks_store.score mocks.keys, run_webmocks, action
  end

  def wait_until(public_id)
    return nil if run_dependencies_only

    channel = nil
    use_retries(5, 1.0 / 24.0) do
      channel = get_channel(id: public_id)
      conclude = yield channel
      break if conclude
    end
    channel
  end

  def response_template
    return nil if run_dependencies_only

    yield
    p last_response.body if expected_res_code != last_response.status
    assert_equal(expected_res_code, last_response.status)
    res = JSON.parse(last_response.body)
    await_call if expected_res_code == 202
    res
  end

  def ok_template
    return nil if run_dependencies_only

    yield
    p last_response.body unless last_response.ok?
    assert last_response.ok?
    assert_equal(200, last_response.status)
    begin
      JSON.parse(last_response.body)
    rescue StandardError
      last_response.body
    end
  end

  def accepted_status_template
    return nil if run_dependencies_only

    yield
    p last_response.body if last_response.status != 202
    assert_equal(202, last_response.status)
    await_call
  end

  private

  def await_call
    # awaiting for async tasks to complete for better error tracking in unit tests.
    active_threads = Thread.list.select { |t| t.status == 'run' }
    active_threads.each { |t| t.join if t.__id__ != Thread.current.__id__ }
  end
end
