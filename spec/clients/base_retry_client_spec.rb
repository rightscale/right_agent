#--
# Copyright (c) 2013 RightScale Inc
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#++

require File.expand_path(File.join(File.dirname(__FILE__), 'spec_helper'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'lib', 'right_agent', 'clients', 'base_retry_client'))

describe RightScale::BaseRetryClient do

  include FlexMock::ArgumentTypes

  before(:each) do
    @log = flexmock(RightScale::Log)
    @log.should_receive(:error).by_default.and_return { |m| raise RightScale::Log.format(*m) }
    @log.should_receive(:warning).by_default.and_return { |m| raise RightScale::Log.format(*m) }
    @url = "http://test.com"
    @timer = flexmock("timer", :cancel => true, :interval= => 0).by_default
    flexmock(EM).should_receive(:reactor_running?).and_return(true).by_default
    flexmock(EM::PeriodicTimer).should_receive(:new).and_return(@timer).by_default
    @http_client = flexmock("http client", :get => true, :check_health => true, :close => true).by_default
    flexmock(RightScale::BalancedHttpClient).should_receive(:new).and_return(@http_client).by_default
    @auth_header = {"Authorization" => "Bearer <session>"}
    @auth_client = AuthClientMock.new(@url, @auth_header)
    @client = RightScale::BaseRetryClient.new
    @options = {:api_version => "2.0"}
    @client.init(:test, @auth_client, @options)
  end

  context :init do
    it "requires auth client to produce URL for specified type of client" do
      lambda { @client.init(:bogus, @auth_client, @options) }.should \
        raise_error(ArgumentError, "Auth client does not support server type :bogus")
    end

    it "requires :api_version option" do
      lambda { @client.init(:test, @auth_client, {}) }.should \
        raise_error(ArgumentError, ":api_version option missing")
    end

    it "initializes options" do
      @options = {
        :server_name => "Test",
        :api_version => "2.0",
        :open_timeout => 1,
        :request_timeout => 2,
        :retry_timeout => 3,
        :retry_intervals => [1, 2, 3],
        :reconnect_interval => 4 }
      @client.init(:test, @auth_client, @options).should be_true
      options = @client.instance_variable_get(:@options)
      options[:server_name].should == "Test"
      options[:api_version].should == "2.0"
      options[:open_timeout].should == 1
      options[:request_timeout].should == 2
      options[:retry_timeout].should == 3
      options[:retry_intervals].should == [1, 2, 3]
      options[:reconnect_interval].should == 4
    end

    it "initializes options to defaults if no value specified" do
      options = @client.instance_variable_get(:@options)
      options[:server_name].should == "test"
      options[:open_timeout].should == 2
      options[:request_timeout].should == 35
      options[:retry_timeout].should == 25
      options[:retry_intervals].should == [4, 12, 36]
      options[:reconnect_interval].should == 15
    end

    it "does not default some options" do
      options = @client.instance_variable_get(:@options)
      options[:retry_enabled].should be_nil
      options[:filter_params].should be_nil
    end

    it "initiates connection and enables use if connected" do
      flexmock(RightScale::BalancedHttpClient).should_receive(:new).and_return(@http_client).once
      @http_client.should_receive(:check_health).once
      flexmock(@client).should_receive(:enable_use).once
      flexmock(@client).should_receive(:reconnect).never
      @client.init(:test, @auth_client, @options).should be_true
      @client.state.should == :connected
    end

    it "sets up for reconnect if not connected" do
      flexmock(RightScale::BalancedHttpClient).should_receive(:new).and_return(@http_client).once
      e = RightScale::BalancedHttpClient::NotResponding.new(nil, RightScale::HttpExceptions.create(503))
      @http_client.should_receive(:check_health).and_raise(e)
      @log.should_receive(:error)
      flexmock(@client).should_receive(:enable_use).never
      flexmock(@client).should_receive(:reconnect).once
      @client.init(:test, @auth_client, @options).should be_false
      @client.state.should == :disconnected
    end
  end

  context :status do
    it "stores callback" do
      callback = lambda { |_, _| }
      @client.instance_variable_get(:@status_callbacks).size.should == 0
      @client.status(&callback)
      @client.instance_variable_get(:@status_callbacks).size.should == 1
      @client.instance_variable_get(:@status_callbacks)[0].should == callback
    end

    it "treats callback as optional" do
      @client.instance_variable_get(:@status_callbacks).size.should == 0
      @client.status
      @client.instance_variable_get(:@status_callbacks).size.should == 0
    end

    it "returns current state" do
      @client.status.should == :connected
    end
  end

  context :communicated do
    it "stores callback" do
      callback = lambda { |_, _| }
      @client.instance_variable_get(:@communicated_callbacks).should be_nil
      @client.communicated(&callback)
      @client.instance_variable_get(:@communicated_callbacks).size.should == 1
      @client.instance_variable_get(:@communicated_callbacks)[0].should == callback
    end

    it "requires callback block" do
      lambda { @client.communicated }.should raise_error(ArgumentError, "Block missing")
     end
  end

  context :close do
    it "sets state to :closed by default" do
      @client.close
      @client.state.should == :closed
    end

    it "cancels reconnect timer" do
      @client.send(:reconnect)
      @timer.should_receive(:cancel).once
      @client.close
    end

    it "sets state to :closing if only closing for receiving" do
      @client.close(:receive)
      @client.state.should == :closing
    end

    it "closes underlying HTTP client connections" do
      @http_client.should_receive(:close).with("terminating").once
      @client.close
    end
  end

  context :state= do
    before(:each) do
      @client.instance_variable_set(:@state, :pending)
    end

    it "raises exception if state transition is invalid" do
      @client.send(:state=, :connected)
      lambda { @client.send(:state=, :pending) }.should raise_error(ArgumentError, "Invalid state transition: :connected -> :pending")
    end

    [:pending, :closed].each do |state|
      context state do
        it "stores new state" do
          @client.send(:state=, state)
          @client.state.should == state
        end
      end
    end

    [:connected, :disconnected, :failed].each do |state|
      context state do
        before(:each) do
          flexmock(@client).should_receive(:reconnect).by_default
        end

        it "stores new state" do
          @client.send(:state=, state)
          @client.state.should == state
        end

        it "stores new state" do
          @client.send(:state=, state).should == state
        end

        context "when callbacks" do
          it "makes callbacks with new state" do
            callback_type = callback_state = nil
            @client.status { |t, s| callback_type = t; callback_state = s }
            @client.send(:state=, state)
            callback_type.should == :test
            callback_state.should == state
          end

          it "log error if callback fails" do
            @log.should_receive(:error).with("Failed status callback", StandardError, :caller).once
            @client.status { |t, s| raise StandardError, "test" }
            @client.send(:state=, state).should == state
          end
        end

        it "reconnects only if transitioning to :disconnected" do
          flexmock(@client).should_receive(:reconnect).times(state == :disconnected ? 1 : 0)
          @client.send(:state=, state)
        end

        it "does nothing if current state is :closed" do
          flexmock(@client.instance_variable_get(:@stats)["state"]).should_receive(:update).once
          @client.send(:state=, :closed)
          @client.send(:state=, state).should == :closed
        end

        it "does nothing if current state is the same" do
          flexmock(@client.instance_variable_get(:@stats)["state"]).should_receive(:update).once
          @client.send(:state=, state)
          @client.send(:state=, state).should == state
        end
      end
    end
  end

  context :create_http_client do
    it "obtains URL from auth client" do
      @log.should_receive(:info).with("Connecting to test via \"http://test.com\"")
      @client.send(:create_http_client)
    end

    it "creates HTTP client" do
      flexmock(RightScale::BalancedHttpClient).should_receive(:new).and_return(@http_client).once
      @client.send(:create_http_client).should == @http_client
    end

    it "uses specified options" do
      @options = {
        :server_name => "Test",
        :api_version => "2.0",
        :open_timeout => 1,
        :request_timeout => 2,
        :filter_params => ["secret"] }
      @client.init(:test, @auth_client, @options)
      flexmock(RightScale::BalancedHttpClient).should_receive(:new).with(@url,
          on { |a| a[:server_name] == "Test" &&
                   a[:api_version] == "2.0" &&
                   a[:filter_params] == ["secret"] }).and_return(@http_client).once
      @client.send(:create_http_client).should == @http_client
    end

    it "closes existing client before creating new one" do
      flexmock(RightScale::BalancedHttpClient).should_receive(:new).and_return(@http_client).twice
      @client.send(:create_http_client).should == @http_client
      @http_client.should_receive(:close).with("reconnecting").once
      @client.send(:create_http_client)
    end
  end

  context :close_http_client do
    it "closes HTTP client" do
      flexmock(@client.instance_variable_get(:@http_client)).should_receive(:close).with("terminating").once
      @client.send(:close_http_client, "terminating").should be true
    end

    it "does nothing if there is no HTTP client" do
      @client.instance_variable_set(:@http_client, nil)
      @client.send(:close_http_client, "terminating").should be true
    end

    it "logs any close exceptions" do
      @log.should_receive(:error).with("Failed closing connection", RuntimeError, :trace).once
      flexmock(@client.instance_variable_get(:@http_client)).should_receive(:close).and_raise(RuntimeError).once
      @client.send(:close_http_client, "terminating").should be false
    end
  end

  context :enable_use do
    it "should return true" do
      @client.send(:enable_use).should be_true
    end
  end

  context :check_health do
    before(:each) do
      flexmock(RightScale::BalancedHttpClient).should_receive(:new).and_return(@http_client).by_default
      @client.send(:create_http_client)
    end

    it "sends health check request using existing HTTP client" do
      @http_client.should_receive(:check_health).once
      @client.send(:check_health)
    end

    it "sets state to :connected" do
      @client.send(:check_health)
      @client.state.should == :connected
    end

    it "returns current state" do
      @client.send(:check_health).should == :connected
    end

    it "sets state to :disconnected and logs if server not responding" do
      e = RightScale::BalancedHttpClient::NotResponding.new("not responding", RightScale::HttpExceptions.create(503))
      @http_client.should_receive(:check_health).and_raise(e).once
      @log.should_receive(:error).with("Failed test health check", RightScale::HttpException, :trace).once
      @client.send(:check_health).should == :disconnected
      @client.state.should == :disconnected
    end

    it "sets state to :disconnected and logs if exception unexpected" do
      @log.should_receive(:error).with("Failed test health check", StandardError, :caller).once
      @http_client.should_receive(:check_health).and_raise(StandardError).once
      @client.send(:check_health).should == :disconnected
      @client.state.should == :disconnected
    end
  end

  context :reconnect do
    before(:each) do
      @client.instance_variable_set(:@reconnecting, nil)
    end

    context 'given EventMachine is running' do
      it "waits random interval for initial reconnect attempt" do
        flexmock(@client).should_receive(:rand).with(15).and_return(10).once
        flexmock(EM::PeriodicTimer).should_receive(:new).with(10, Proc).and_return(@timer).once
        @client.send(:reconnect).should be_true
      end

      it "attempts to connect even if currently connected" do
        flexmock(EM::PeriodicTimer).should_receive(:new).and_return(@timer).and_yield
        @client.send(:create_http_client)
        @client.send(:check_health).should == :connected
        flexmock(@client).should_receive(:check_health).once
        @client.send(:reconnect).should be_true
      end

      it "recreates HTTP client and checks health" do
        flexmock(EM::PeriodicTimer).should_receive(:new).and_return(@timer).and_yield
        flexmock(RightScale::BalancedHttpClient).should_receive(:new).and_return(@http_client).once
        @http_client.should_receive(:check_health).once
        @client.send(:reconnect).should be_true
      end

      context "when health check successful" do
        it "enables use of client" do
          flexmock(EM::PeriodicTimer).should_receive(:new).and_return(@timer).and_yield
          flexmock(@client).should_receive(:enable_use).once
          @client.send(:reconnect).should be_true
        end

        it "rechecks state after enables use" do
          flexmock(EM::PeriodicTimer).should_receive(:new).and_return(@timer).and_yield
          flexmock(@client).should_receive(:enable_use).and_return { @client.instance_variable_set(:@state, :disconnected) }.once
          @client.send(:reconnect).should be_true
          @client.instance_variable_get(:@reconnecting).should be true
        end

        it "disables timer" do
          @client.send(:reconnect); @client.instance_variable_set(:@reconnecting, nil) # to get @reconnect_timer initialized
          @client.instance_variable_set(:@reconnecting, nil)
          @timer.should_receive(:cancel).once
          flexmock(EM::PeriodicTimer).should_receive(:new).and_return(@timer).and_yield
          @client.send(:reconnect).should be_true
          @client.instance_variable_get(:@reconnecting).should be_nil
        end

        it "does not reset timer interval" do
          @timer.should_receive(:interval=).never
          flexmock(EM::PeriodicTimer).should_receive(:new).and_return(@timer).and_yield
          @client.send(:reconnect).should be_true
        end
      end

      context "when reconnect fails" do
        it "logs error if exception is raised" do
          flexmock(EM::PeriodicTimer).should_receive(:new).and_return(@timer).and_yield
          flexmock(@client).should_receive(:enable_use).and_raise(StandardError).once
          @log.should_receive(:error).with("Failed test reconnect", StandardError, :caller).once
          @client.send(:reconnect).should be_true
          @client.state.should == :disconnected
        end

        it "resets the timer interval to the configured value" do
          @client.send(:reconnect); @client.instance_variable_set(:@reconnecting, nil) # to get @reconnect_timer initialized
          @log.should_receive(:error).with("Failed test health check", StandardError, :caller).once
          @http_client.should_receive(:check_health).and_raise(StandardError).once
          @timer.should_receive(:interval=).with(15).once
          flexmock(EM::PeriodicTimer).should_receive(:new).and_return(@timer).and_yield
          @client.send(:reconnect).should be_true
        end
      end

      it "does nothing if already reconnecting" do
        flexmock(EM::PeriodicTimer).should_receive(:new).and_return(@timer).once
        @client.send(:reconnect).should be_true
        @client.instance_variable_get(:@reconnecting).should be_true
        @client.send(:reconnect).should be_true
        @client.instance_variable_get(:@reconnecting).should be_true
      end
    end

    context 'given EventMachine is inactive' do
      before(:each) do
        flexmock(EM).should_receive(:reactor_running?).and_return(false)
      end

      it "tries once" do
        @client.send(:reconnect).should be_true
      end

      it "raises exceptions" do
        lambda do
          flexmock(@client).should_receive(:create_http_client).and_raise(Exception)

          @client.send(:reconnect)
        end.should raise_error(Exception)
      end
    end
  end

  context :make_request do
    before(:each) do
      @path = "/foo/bar"
      @params = {:some => "data"}
      @request_uuid = "random uuid"
      @now = Time.now
      @expires_at = @now + 25
      flexmock(Time).should_receive(:now).and_return(@now).by_default
      flexmock(RightSupport::Data::UUID).should_receive(:generate).and_return(@request_uuid)
      flexmock(EM::PeriodicTimer).should_receive(:new).and_return(@timer).and_yield
      @client.instance_variable_set(:@reconnecting, nil)
      @client.init(:test, @auth_client, @options)
    end

    context 'given EventMachine is inactive' do
      before(:each) do
        flexmock(EM).should_receive(:reactor_running?).and_return(false)
      end

      it 'reconnects if necessary' do
        @client.instance_variable_set(:@state, :disconnected)
        @http_client.should_receive(:get).with(@path, @params, Hash).once
        @client.send(:make_request, :get, @path, @params)
      end

      it 'raises connection errors' do
        @client.instance_variable_set(:@state, :disconnected)
        @http_client.should_receive(:check_health).and_raise(Exception)
        lambda {
          @client.send(:make_request, :get, @path, @params)
        }.should raise_error(Exception)
      end
    end

    it "raises exception if terminating" do
      @client.close
      lambda { @client.send(:make_request, :get, @path) }.should raise_error(RightScale::Exceptions::Terminating)
    end

    it "generates a request UUID if none specified" do
      @http_client.should_receive(:get).with(@path, @params, hsh(:request_uuid => @request_uuid)).once
      @client.send(:make_request, :get, @path, @params)
    end

    it "raises exception if not connected" do
      @client.send(:state=, :failed)
      lambda { @client.send(:make_request, :get, @path) }.
          should raise_error(RightScale::Exceptions::ConnectivityFailure, "test client not connected")
    end

    it "sets HTTP options for request" do
      @http_client.should_receive(:get).with(@path, @params,
          on { |a| a[:open_timeout] == 2 &&
                   a[:request_timeout] == 35 &&
                   a[:request_uuid] == "uuid" &&
                   a[:headers] == @auth_header }).once
      @client.send(:make_request, :get, @path, @params, nil, :request_uuid => "uuid")
    end

    it "overrides HTTP options with those supplied on request" do
      @http_client.should_receive(:get).with(@path, @params,
          on { |a| a[:open_timeout] == 2 &&
                   a[:request_timeout] == 20 &&
                   a[:headers] == @auth_header }).once
      @client.send(:make_request, :get, @path, @params, nil, {:request_timeout => 20})
    end

    it "sets X-Expires-At header if time-to-live specified" do
      @http_client.should_receive(:get).with(@path, @params,
          on { |a| a[:headers] == @auth_header.merge("X-Expires-At" => @now + 99) }).once
      @client.send(:make_request, :get, @path, @params, nil, :time_to_live => 99)
    end

    it "does not set X-Expires-At header if time-to-live is non-positive" do
      @http_client.should_receive(:get).with(@path, @params, on { |a| a[:headers] == @auth_header }).once
      @client.send(:make_request, :get, @path, @params, nil, :time_to_live => -1)
    end

    it "makes request using HTTP client" do
      @http_client.should_receive(:get).with(@path, @params, Hash).once
      @client.send(:make_request, :get, @path, @params)
    end

    it "makes communicated callbacks" do
      @http_client.should_receive(:get).once
      called = 0
      @client.communicated { called += 1 }
      @client.send(:make_request, :get, @path, @params)
      called.should == 1
    end

    context "when exception" do
      it "handles any exceptions" do
        @http_client.should_receive(:get).and_raise(StandardError, "test").once
        flexmock(@client).should_receive(:handle_exception).with(StandardError, "type", @request_uuid, @expires_at, 1).
            and_raise(StandardError, "failed").once
        lambda { @client.send(:make_request, :get, @path, @params, "type") }.should raise_error(StandardError, "failed")
      end

      it "uses path for request type if no request type specified" do
        @http_client.should_receive(:get).and_raise(StandardError, "test").once
        flexmock(@client).should_receive(:handle_exception).with(StandardError, @path, @request_uuid, @expires_at, 1).
            and_raise(StandardError, "failed").once
        lambda { @client.send(:make_request, :get, @path, @params) }.should raise_error(StandardError, "failed")
      end

      it "uses specified time-to-live to control how long to retry if less than configured retry timeout" do
        @http_client.should_receive(:get).and_raise(StandardError, "test").once
        flexmock(@client).should_receive(:handle_exception).with(StandardError, @path, @request_uuid, @now + 19, 1).
            and_raise(StandardError, "failed").once
        lambda { @client.send(:make_request, :get, @path, @params, nil, :time_to_live => 19) }.should raise_error(StandardError, "failed")
      end

      it "uses configure retry timeout to control how long to retry if time-to-live exceeds it" do
        @http_client.should_receive(:get).and_raise(StandardError, "test").once
        flexmock(@client).should_receive(:handle_exception).with(StandardError, @path, @request_uuid, @expires_at, 1).
            and_raise(StandardError, "failed").once
        lambda { @client.send(:make_request, :get, @path, @params, nil, :time_to_live => 99) }.should raise_error(StandardError, "failed")
      end

      it "retries if exception handling does not result in raise" do
        @http_client.should_receive(:get).and_raise(StandardError, "test").twice
        flexmock(@client).should_receive(:handle_exception).with(StandardError, @path, @request_uuid, @expires_at, 1).
            and_return("updated uuid").once.ordered
        flexmock(@client).should_receive(:handle_exception).with(StandardError, @path, "updated uuid", @expires_at, 2).
            and_raise(StandardError, "failed").once.ordered
        lambda { @client.send(:make_request, :get, @path, @params) }.should raise_error(StandardError, "failed")
      end
    end

    it "returns result of request" do
      @http_client.should_receive(:get).with(@path, @params, Hash).and_return("result").once
      @client.send(:make_request, :get, @path, @params).should == "result"
    end
  end

  context "make_request failures" do
    before(:each) do
      @type = "type"
      @request_uuid = "random uuid"
      @later = (@now = Time.now)
      flexmock(Time).should_receive(:now).and_return { @later += 1 }
      @expires_at = @now + 25
      flexmock(RightSupport::Data::UUID).should_receive(:generate).and_return(@request_uuid)
      flexmock(EM::PeriodicTimer).should_receive(:new).and_return(@timer).and_yield
      @client.instance_variable_set(:@reconnecting, nil)
      @client.init(:test, @auth_client, @options.merge(:retry_enabled => true))
    end

    context :handle_exception do
      context "when redirect" do
        [301, 302].each do |http_code|
          it "handles #{http_code} redirect" do
            e = RightScale::HttpExceptions.create(http_code, "redirect")
            flexmock(@client).should_receive(:handle_redirect).with(e, @type, @request_uuid).once
            @client.send(:handle_exception, e, @type, @request_uuid, @expires_at, 1)
          end
        end
      end

      it "raises if unauthorized" do
        e = RightScale::HttpExceptions.create(401, "unauthorized")
        lambda { @client.send(:handle_exception, e, @type, @request_uuid, @expires_at, 1) }.should \
            raise_error(RightScale::Exceptions::Unauthorized, "unauthorized")
      end

      it "notifies auth client and raises retryable if session expired" do
        e = RightScale::HttpExceptions.create(403, "forbidden")
        lambda { @client.send(:handle_exception, e, @type, @request_uuid, @expires_at, 1) }.should \
            raise_error(RightScale::Exceptions::RetryableError, "Authorization expired")
        @auth_client.expired_called.should be_true
      end

      it "handles retry with and updates request_uuid to distinguish for retry" do
        e = RightScale::HttpExceptions.create(449, "retry with")
        flexmock(@client).should_receive(:handle_retry_with).with(e, @type, @request_uuid, @expires_at, 1).
            and_return("modified uuid").once
        @client.send(:handle_exception, e, @type, @request_uuid, @expires_at, 1).should == "modified uuid"
      end

      it "handles internal server error" do
        e = RightScale::HttpExceptions.create(500, "test internal error")
        lambda { @client.send(:handle_exception, e, @type, @request_uuid, @expires_at, 1) }.should \
            raise_error(RightScale::Exceptions::InternalServerError, "test internal error")
      end

      it "handles not responding" do
        e = RightScale::BalancedHttpClient::NotResponding.new("not responding")
        flexmock(@client).should_receive(:handle_not_responding).with(e, @type, @request_uuid, @expires_at, 1).once
        @client.send(:handle_exception, e, @type, @request_uuid, @expires_at, 1)
      end

      it "causes other HTTP exceptions to be re-raised by returning nil" do
        e = RightScale::HttpExceptions.create(400, "bad request")
        @client.send(:handle_exception, e, @type, @request_uuid, @expires_at, 1).should be_nil
      end

      it "causes other non-HTTP exceptions to be re-raised by returning nil" do
        @client.send(:handle_exception, StandardError, @type, @request_uuid, @expires_at, 1).should be_nil
      end
    end

    context :handle_redirect do
      it "initiates redirect by notifying auth client and raising retryable error" do
        location = "http://somewhere.com"
        e = RightScale::HttpExceptions.create(301, "moved permanently", {:location => location})
        @log.should_receive(:info).with(/Received REDIRECT/).once.ordered
        @log.should_receive(:info).with("Requesting auth client to handle redirect to #{location.inspect}").once.ordered
        lambda { @client.send(:handle_redirect, e, @type, @request_uuid) }.should \
            raise_error(RightScale::Exceptions::RetryableError, "moved permanently")
        @auth_client.redirect_location.should == location
      end

      it "raises internal error if no redirect location is provided" do
        e = RightScale::HttpExceptions.create(301, "moved permanently")
        @log.should_receive(:info).with(/Received REDIRECT/).once
        lambda { @client.send(:handle_redirect, e, @type, @request_uuid) }.should \
            raise_error(RightScale::Exceptions::InternalServerError, "No redirect location provided")
      end
    end

    context :handle_retry_with do
      before(:each) do
        @exception = RightScale::HttpExceptions.create(449, "retry with")
      end

      it "waits for configured interval and does not raise if retry still viable" do
        @log.should_receive(:error).with(/Retrying type request/).once
        flexmock(@client).should_receive(:sleep).with(4).once
        @client.send(:handle_retry_with, @exception, @type, @request_uuid, @expires_at, 1)
      end

      it "returns modified request_uuid" do
        @log.should_receive(:error)
        flexmock(@client).should_receive(:sleep)
        @client.send(:handle_retry_with, @exception, @type, @request_uuid, @expires_at, 1).should == "#{@request_uuid}:retry"
      end

      it "does not retry more than once" do
        lambda { @client.send(:handle_retry_with, @exception, @type, @request_uuid, @expires_at, 2) }.should \
            raise_error(RightScale::Exceptions::RetryableError)
      end

      it "raises retryable error if retry timed out" do
        @client.init(:test, @auth_client, @options.merge(:retry_enabled => true, :retry_timeout => 10))
        lambda { @client.send(:handle_retry_with, @exception, @type, @request_uuid, @now + 10, 1) }.should \
            raise_error(RightScale::Exceptions::RetryableError)
      end

      it "raises retryable error if retry disabled" do
        @client.init(:test, @auth_client, @options.merge(:retry_enabled => false))
        lambda { @client.send(:handle_retry_with, @exception, @type, @request_uuid, @expires_at, 1) }.should \
            raise_error(RightScale::Exceptions::RetryableError)
      end
    end

    context :handle_not_responding do
      before(:each) do
        @exception = RightScale::BalancedHttpClient::NotResponding.new("Server not responding")
      end

      it "waits for configured interval and does not raise if retry still viable" do
        @log.should_receive(:error).with(/Retrying type request/).once
        flexmock(@client).should_receive(:sleep).with(4).once
        @client.send(:handle_not_responding, @exception, @type, @request_uuid, @expires_at, 1)
      end

      it "changes wait interval for successive retries" do
        @log.should_receive(:error).with(/Retrying type request/).once
        flexmock(@client).should_receive(:sleep).with(12).once
        @client.send(:handle_not_responding, @exception, @type, @request_uuid, @expires_at, 2)
      end

      it "sets state to :disconnected and raises connectivity error if retry timed out" do
        @client.init(:test, @auth_client, @options.merge(:retry_enabled => true, :retry_timeout => 10))
        # Need to shut off reconnect, otherwise since timers are always yielding,
        # setting state to :disconnected sets it to :connected
        flexmock(@client).should_receive(:reconnect).once
        lambda { @client.send(:handle_not_responding, @exception, @type, @request_uuid, @now + 10, 3) }.should \
            raise_error(RightScale::Exceptions::ConnectivityFailure, "Server not responding after 3 attempts")
        @client.state.should == :disconnected
      end

      it "sets state to :disconnected and raises connectivity error if retry disabled" do
        @client.init(:test, @auth_client, @options.merge(:retry_enabled => false))
        # Need to shut off reconnect, otherwise since timers are always yielding,
        # setting state to :disconnected sets it to :connected
        flexmock(@client).should_receive(:reconnect).once
        lambda { @client.send(:handle_not_responding, @exception, @type, @request_uuid, @expires_at, 1) }.should \
            raise_error(RightScale::Exceptions::ConnectivityFailure, "Server not responding")
        @client.state.should == :disconnected
      end
    end

    context :retry_interval do
      [[1, 4], [2, 12], [3, 36], [4, 36]].each do |attempt, interval|
        it "returns retry interval when should retry after attempt #{attempt}" do
          @client.send(:retry_interval, @now + 120, attempt).should == interval
        end
      end

      it "returns 0 if another retry would exceed expiration time" do
        @client.send(:retry_interval, @now + 11, 2).should == 0
      end

      it "returns 0 if exceeded max retries" do
        @client.send(:retry_interval, @expires_at, 2, 1).should == 0
      end

      it "returns nil if retry disabled" do
        @client.init(:test, @auth_client, @options.merge(:retry_enabled => false))
        @client.send(:retry_interval, @expires_at, 1).should be nil
      end
    end

    context :wait do
      it "waits using timer if non-blocking enabled" do
        @fiber = flexmock("fiber", :resume => true).by_default
        flexmock(Fiber).should_receive(:current).and_return(@fiber)
        flexmock(Fiber).should_receive(:yield).once
        flexmock(EM).should_receive(:add_timer).with(1, Proc).and_yield.once
        @client.init(:test, @auth_client, @options.merge(:non_blocking => true))
        @client.send(:wait, 1).should be true
      end

      it " waits using sleep if non-blocking disabled" do
        flexmock(@client).should_receive(:sleep).with(1).once
        @client.send(:wait, 1).should be true
      end
    end
  end
end
