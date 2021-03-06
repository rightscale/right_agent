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
require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'lib', 'right_agent', 'clients', 'router_client'))

describe RightScale::RouterClient do

  include FlexMock::ArgumentTypes

  before(:each) do
    @log = flexmock(RightScale::Log)
    @log.should_receive(:error).by_default.and_return { |m| raise RightScale::Log.format(*m) }
    @log.should_receive(:warning).by_default.and_return { |m| raise RightScale::Log.format(*m) }
    @timer = flexmock("timer", :cancel => true).by_default
    flexmock(EM::Timer).should_receive(:new).and_return(@timer).by_default
    @http_client = flexmock("http client", :get => true, :check_health => true, :close => true).by_default
    flexmock(RightScale::BalancedHttpClient).should_receive(:new).and_return(@http_client).by_default
    @websocket = WebSocketClientMock.new
    flexmock(Faye::WebSocket::Client).should_receive(:new).and_return(@websocket).by_default
    @auth_header = {"Authorization" => "Bearer <session>"}
    @url = "http://test.com"
    @ws_url = "ws://test.com"
    @auth_client = AuthClientMock.new(@url, @auth_header, :authorized)
    @routing_keys = nil
    @options = {}
    @client = RightScale::RouterClient.new(@auth_client, @options)
    @version = RightScale::AgentConfig.protocol_version
    @event = {:uuid => "uuid", :type => "Push", :path => "/foo/bar", :from => "rs-agent-1-1", :data => {}, :version => @version}
  end

  context :initialize do
    it "initializes options" do
      @options = {
        :open_timeout => 1,
        :request_timeout => 2,
        :listen_timeout => 3,
        :retry_timeout => 4,
        :retry_intervals => [1, 2, 3],
        :reconnect_interval => 5 }
      @client = RightScale::RouterClient.new(@auth_client, @options)
      options = @client.instance_variable_get(:@options)
      options[:server_name] = "RightNet"
      options[:api_version] = "2.0"
      options[:open_timeout] = 1
      options[:request_timeout] = 2
      options[:listen_timeout] = 3
      options[:retry_timeout] = 4
      options[:retry_intervals] = [1, 2, 3]
      options[:reconnect_interval] = 5
    end

    it "initializes options to defaults if no value specified" do
      options = @client.instance_variable_get(:@options)
      options[:listen_timeout].should == 60
    end
  end

  context "requests" do

    before(:each) do
      @type = "/foo/bar"
      @action = "bar"
      @payload = {:some => "data"}
      @target = "rs-agent-2-2"
      @params = {
        :type => @type,
        :payload => @payload,
        :target => @target }
    end

    [:push, :request].each do |kind|
      context kind do
        it "makes post request to router" do
          flexmock(@client).should_receive(:make_request).with(:post, "/#{kind}", @params, @action, {}).and_return(nil).once
          @client.send(kind, @type, @payload, @target).should be nil
        end

        it "applies request options" do
          options = {:request_uuid => "uuid", :time_to_live => 60}
          flexmock(@client).should_receive(:make_request).with(:post, "/#{kind}", @params, @action, options).and_return(nil).once
          @client.send(kind, @type, @payload, @target, options).should be nil
        end
      end
    end
  end

  context "events" do

    def when_in_listen_state(state, checks = nil, failures = 0)
      flexmock(EM).should_receive(:next_tick).by_default
      flexmock(EM::Timer).should_receive(:new).and_return(@timer).by_default
      @client.send(:update_listen_state, state)
      @client.instance_variable_set(:@listen_checks, checks) if checks
      @client.instance_variable_set(:@listen_failures, failures)
      @client.instance_variable_set(:@connect_interval, 30)
      @client.instance_variable_set(:@reconnect_interval, 2)
      state
    end

    before(:each) do
      @handler = lambda { |_| }
      @later = Time.at(@now = Time.now)
      @tick = 1
      flexmock(Time).should_receive(:now).and_return { @later += @tick }
    end

    context :notify do
      before(:each) do
        @routing_keys = ["key"]
        @params = {
          :event => @event,
          :routing_keys => @routing_keys }
      end

      it "sends using websocket if available" do
        @client.send(:connect, @routing_keys) { |_| }
        @client.notify(@event, @routing_keys).should be true
        @websocket.sent.should == JSON.dump(@params)
      end

      it "makes post request by default" do
        flexmock(@client).should_receive(:make_request).with(:post, "/notify", @params, "notify",
                                                             {:request_uuid => "uuid", :filter_params => ["event"]}).once
        @client.notify(@event, @routing_keys).should be true
      end
    end

    context :listen do
      it "raises if block missing" do
        lambda { @client.listen(@routing_keys) }.should raise_error(ArgumentError, "Block missing")
      end

      it "initializes listen state and starts loop" do
        flexmock(@client).should_receive(:listen_loop).with(@routing_keys, Proc).and_return(true).once
        @client.listen(@routing_keys, &@handler).should be true
        @client.instance_variable_get(:@listen_state).should == :choose
      end
    end

    context :close do
      it "stops listening" do
        @client.instance_variable_set(:@listen_timer, @timer)
        @timer.should_receive(:cancel).once
        @client.close
        @client.instance_variable_get(:@listen_timer).should be nil
        @client.instance_variable_get(:@listen_state).should == :cancel
      end

      it "closes websocket" do
        @client.send(:connect, nil, &@handler)
        @client.close
        @websocket.closed.should be true
        @websocket.code.should == 1001
      end
    end

    context :update_listen_state do
      it "cancels timer if state is :cancel" do
        @client.instance_variable_set(:@listen_timer, @timer)
        @client.send(:update_listen_state, :cancel).should be true
        @client.instance_variable_get(:@listen_state).should == :cancel
        @client.instance_variable_get(:@listen_timer).should be nil
      end

      it "can handle a re-cancel" do
        @client.instance_variable_set(:@listen_timer, @timer)
        @client.send(:update_listen_state, :cancel).should be true
        @client.send(:update_listen_state, :cancel).should be true
        @client.instance_variable_get(:@listen_timer).should be nil
      end

      [:choose, :check, :connect, :long_poll, :wait].each do |state|
        it "sets state and timer interval for valid state #{state}" do
          @client.send(:update_listen_state, state, 10).should be true
          @client.instance_variable_get(:@listen_state).should == state
          @client.instance_variable_get(:@listen_interval).should == 10
        end
      end

      it "rejects invalid states" do
        lambda { @client.send(:update_listen_state, :bogus) }.should raise_error(ArgumentError)
      end

      context "and state set to :check" do
        it "initializes check count" do
          @client.instance_variable_get(:@listen_checks).should be nil
          @client.send(:update_listen_state, :check).should be true
          @client.instance_variable_get(:@listen_checks).should == 0
        end

        it "only records start of long-polling when state changes" do
          @client.send(:update_listen_state, :check).should be true
          @client.instance_variable_get(:@listen_checks).should == 0
          @client.instance_variable_set(:@listen_checks, nil)
          @client.send(:update_listen_state, :check)
          @client.instance_variable_get(:@listen_checks).should be nil
        end
      end
    end

    context :listen_loop do
      context "in :choose state" do
        it "chooses listen method" do
          when_in_listen_state(:choose)
          @client.send(:listen_loop, @routing_keys, &@handler)
          @client.instance_variable_get(:@listen_state).should == :connect
        end
      end

      context "in :check state" do
        context "and not connected" do
          before(:each) do
            when_in_listen_state(:check)
            @client.instance_variable_set(:@websocket, nil)
          end

          it "sets state to :connect if router not responding" do
            flexmock(@client).should_receive(:router_not_responding?).and_return(true).once
            @client.send(:listen_loop, @routing_keys, &@handler)
            @client.instance_variable_get(:@listen_state).should == :connect
            @client.instance_variable_get(:@listen_interval).should == 4
          end

          it "otherwise backs off connect interval and sets state to :long_poll" do
            flexmock(@client).should_receive(:router_not_responding?).and_return(false).once
            @client.send(:listen_loop, @routing_keys, &@handler)
            @client.instance_variable_get(:@connect_interval).should == 60
            @client.instance_variable_get(:@listen_state).should == :long_poll
            @client.instance_variable_get(:@listen_interval).should == 0
          end
        end

        context "and connected" do
          before(:each) do
            @client.instance_variable_set(:@websocket, @websocket)
          end

          it "sets state to :choose if have checked enough" do
            when_in_listen_state(:check, 5)
            @client.send(:listen_loop, @routing_keys, &@handler)
            @client.instance_variable_get(:@listen_state).should == :choose
            @client.instance_variable_get(:@listen_interval).should == 30
          end

          it "otherwise stays in same state" do
            when_in_listen_state(:check, 4)
            @client.send(:listen_loop, @routing_keys, &@handler)
            @client.instance_variable_get(:@listen_state).should == :check
          end
        end
      end

      context "in :connect state" do
       it "tries to connect" do
          when_in_listen_state(:connect)
          flexmock(@client).should_receive(:try_connect).with(@routing_keys, Proc).once
          @client.send(:listen_loop, @routing_keys, &@handler)
        end
      end

      context "in :long_poll state" do
        it "tries long-polling if non-blocking enabled" do
          @client = RightScale::RouterClient.new(@auth_client, :non_blocking => true)
          when_in_listen_state(:long_poll)
          event_uuids = ["uuids"]
          flexmock(@client).should_receive(:try_long_poll).with(@routing_keys, nil, Proc).and_return(event_uuids).once
          @client.send(:listen_loop, @routing_keys, &@handler)
          @client.instance_variable_get(:@event_uuids).should == event_uuids
        end

        it "otherwise tries deferred long-polling and sets state to :wait" do
          when_in_listen_state(:long_poll)
          event_uuids = ["uuids"]
          @client.instance_variable_set(:@event_uuids, event_uuids)
          flexmock(@client).should_receive(:try_deferred_long_poll).with(@routing_keys, event_uuids, Proc).once
          @client.send(:listen_loop, @routing_keys, &@handler)
          @client.instance_variable_get(:@listen_state).should == :wait
          @client.instance_variable_get(:@listen_interval).should == 1
        end
      end

      context "in :wait state" do
        it "does nothing" do
          when_in_listen_state(:wait)
          @client.send(:listen_loop, @routing_keys, &@handler)
          @client.instance_variable_get(:@listen_state).should == :wait
        end
      end

      context "in :cancel state" do
        it "returns false" do
          when_in_listen_state(:cancel)
          @client.send(:listen_loop, @routing_keys, &@handler).should be false
          @client.instance_variable_get(:@listen_state).should == :cancel
        end
      end

      context "when unexpected exception" do
        before(:each) do
          when_in_listen_state(:connect)
          flexmock(@client).should_receive(:try_connect).and_raise(RuntimeError).once
        end

        it "logs error" do
          @log.should_receive(:error).with("Failed to listen", RuntimeError, :trace).once
          @client.send(:listen_loop, @routing_keys, &@handler).should be true
        end

        it "resets state to :choose" do
          @log.should_receive(:error)
          @client.send(:listen_loop, @routing_keys, &@handler).should be true
          @client.instance_variable_get(:@listen_state).should == :choose
        end

        it "fails if exceeded repeated failure limit" do
          when_in_listen_state(:connect, 1, 10)
          @log.should_receive(:error).with("Failed to listen", RuntimeError, :trace).once.ordered
          @log.should_receive(:error).with("Exceeded maximum repeated listen failures (10), stopping listening").once.ordered
          @client.send(:listen_loop, @routing_keys, &@handler).should be false
          @client.instance_variable_get(:@listen_state).should == :cancel
          @client.state.should == :failed
        end
      end

      it "waits required amount of time before looping" do
        when_in_listen_state(:choose)
        flexmock(@client).should_receive(:listen_loop_wait).with(@later + 1, 0, @routing_keys, @handler).and_return(true).once
        @client.send(:listen_loop, @routing_keys, &@handler).should be true
      end
    end

    context :listen_loop_wait do
      it "uses next_tick for next loop if interval is 0" do
        when_in_listen_state(:choose)
        @client.instance_variable_get(:@listen_interval).should == 0
        flexmock(EM).should_receive(:next_tick).and_yield.once
        flexmock(EM::Timer).should_receive(:new).never
        flexmock(@client).should_receive(:listen_loop).with(@routing_keys, @handler).once
        @client.send(:listen_loop_wait, 0, @later, @routing_keys, &@handler).should be true
      end

      it "otherwise uses timer for next loop" do
        when_in_listen_state(:long_poll)
        @client.instance_variable_set(:@listen_interval, 9)
        flexmock(EM::Timer).should_receive(:new).with(9, Proc).and_return(@timer).and_yield.once
        flexmock(EM).should_receive(:next_tick).never
        flexmock(@client).should_receive(:listen_loop).with(@routing_keys, @handler).once
        @client.send(:listen_loop_wait, @later - 9, 9, @routing_keys, &@handler).should be true
      end

      it "waits some more if interval has changed while waiting" do
        when_in_listen_state(:long_poll)
        @client.instance_variable_set(:@listen_interval, 3)
        flexmock(EM::Timer).should_receive(:new).with(1, Proc).and_return(@timer).and_yield.once.ordered
        flexmock(EM::Timer).should_receive(:new).with(2, Proc).and_return(@timer).and_yield.once.ordered
        flexmock(EM::Timer).should_receive(:new).with(1, Proc).and_return(@timer).and_yield.once.ordered
        flexmock(EM).should_receive(:next_tick).never
        flexmock(@client).should_receive(:listen_loop).with(@routing_keys, @handler).once
        @client.send(:listen_loop_wait, @later, 1, @routing_keys, &@handler).should be true
      end
    end

    context :choose_listen_method do
      before(:each) do
        @client.instance_variable_set(:@connect_interval, 30)
      end

      it "chooses long-polling if only it is enabled" do
        @client = RightScale::RouterClient.new(@auth_client, :long_polling_only => true)
        @client.send(:choose_listen_method).should be true
        @client.instance_variable_get(:@listen_state).should == :long_poll
        @client.instance_variable_get(:@listen_interval).should == 0
        @client.instance_variable_get(:@connect_interval).should == 60 * 60 * 24
      end

      it "chooses to delay choice if already connected" do
        @client.instance_variable_set(:@websocket, @websocket)
        @client.send(:choose_listen_method).should be true
        @client.instance_variable_get(:@listen_state).should == :choose
        @client.instance_variable_get(:@listen_interval).should == 30
      end

      context "when not connected" do
        before(:each) do
          @client.instance_variable_get(:@websocket).should be nil
        end

        it "chooses to connect if never connected" do
          @client.send(:choose_listen_method).should be true
          @client.instance_variable_get(:@listen_state).should == :connect
          @client.instance_variable_get(:@listen_interval).should == 0
        end

        context "but previously attempted" do
          before(:each) do
            @client.instance_variable_set(:@attempted_connect_at, @now)
          end

          it "chooses to connect immediately if enough time has elapsed" do
            @client.instance_variable_set(:@attempted_connect_at, @now - 30)
            @client.send(:choose_listen_method).should be true
            @client.instance_variable_get(:@listen_state).should == :connect
            @client.instance_variable_get(:@listen_interval).should == 0
          end

          [RightScale::RouterClient::NORMAL_CLOSE, RightScale::RouterClient::SHUTDOWN_CLOSE].each do |code|
            it "chooses to connect immediately if previous close code is #{code}" do
              @client.instance_variable_set(:@close_code, code)
              @client.instance_variable_set(:@connect_interval, 300)
              @client.send(:choose_listen_method).should be true
              @client.instance_variable_get(:@listen_state).should == :connect
              @client.instance_variable_get(:@listen_interval).should == 0
            end
          end

          [408, 502, 503].each do |code|
            it "chooses to connect immediately if previous close code #{code} indicates router not responding" do
              @client.instance_variable_set(:@close_code, RightScale::RouterClient::PROTOCOL_ERROR_CLOSE)
              @client.instance_variable_set(:@close_reason, "Unexpected response code: #{code}")
              @client.instance_variable_set(:@connect_interval, 300)
              @client.send(:choose_listen_method).should be true
              @client.instance_variable_get(:@listen_state).should == :connect
              @client.instance_variable_get(:@listen_interval).should == 0
            end
          end

          it "otherwise it chooses to connect as soon as connect interval expires" do
            @client.instance_variable_set(:@attempted_connect_at, @now - 28)
            @client.send(:choose_listen_method).should be true
            @client.instance_variable_get(:@listen_state).should == :connect
            @client.instance_variable_get(:@listen_interval).should == 1
          end
        end
      end
    end

    context :try_connect do
      before(:each) do
        @client.instance_variable_get(:@websocket).should be nil
        @client.instance_variable_set(:@connect_interval, 30)
        @client.instance_variable_set(:@reconnect_interval, 2)
      end

      it "makes websocket connect request and sets state to :check" do
        flexmock(Faye::WebSocket::Client).should_receive(:new).and_return(@websocket).once
        @client.send(:try_connect, @routing_keys, &@handler)
        @client.instance_variable_get(:@listen_state).should == :check
        @client.instance_variable_get(:@listen_interval).should == 1
      end

      it "adjusts connect interval if websocket creation fails and sets state to :long_poll" do
        @log.should_receive(:error).with("Failed creating WebSocket", RuntimeError, :caller).once
        flexmock(Faye::WebSocket::Client).should_receive(:new).and_raise(RuntimeError).once
        @client.send(:try_connect, @routing_keys, &@handler)
        @client.instance_variable_get(:@connect_interval).should == 60
        @client.instance_variable_get(:@listen_state).should == :long_poll
        @client.instance_variable_get(:@listen_interval).should == 0
      end
    end

    context :connect do
      it "raises if block missing" do
        lambda { @client.send(:connect, @routing_keys) }.should raise_error(ArgumentError, "Block missing")
      end

      context "when creating connection" do
        it "connects to router" do
          flexmock(Faye::WebSocket::Client).should_receive(:new).with(@ws_url + "/connect", nil, Hash).and_return(@websocket).once
          @client.send(:connect, @routing_keys, &@handler)
        end

        it "chooses scheme based on scheme in router URL" do
          @url = "https://test.com"
          @ws_url = "wss://test.com"
          @auth_client = AuthClientMock.new(@url, @auth_header, :authorized)
          @client = RightScale::RouterClient.new(@auth_client, @options)
          flexmock(Faye::WebSocket::Client).should_receive(:new).with(@ws_url + "/connect", nil, Hash).and_return(@websocket).once
          @client.send(:connect, @routing_keys, &@handler)
        end

        it "uses headers containing only API version and authorization" do
          headers = @auth_header.merge("X-API-Version" => "2.0")
          flexmock(Faye::WebSocket::Client).should_receive(:new).with(String, nil, hsh(:headers => headers)).and_return(@websocket).once
          @client.send(:connect, @routing_keys, &@handler)
        end

        it "enables ping" do
          flexmock(Faye::WebSocket::Client).should_receive(:new).with(String, nil, hsh(:ping => 60)).and_return(@websocket).once
          @client.send(:connect, @routing_keys, &@handler)
        end

        it "adds routing keys as query parameters" do
          url = @ws_url + "/connect" + "?routing_keys[]=a%3Ab%3Dc"
          flexmock(Faye::WebSocket::Client).should_receive(:new).with(url, nil, Hash).and_return(@websocket).once
          @client.send(:connect, ["a:b=c"], &@handler)
        end

        it "returns websocket" do
          flexmock(Faye::WebSocket::Client).should_receive(:new).and_return(@websocket).once
          @client.send(:connect, @routing_keys, &@handler).should == @websocket
          @client.instance_variable_get(:@websocket).should == @websocket
        end
      end

      context "when message received" do
        before(:each) do
          @json_event = JSON.dump(@event)
          @json_ack = JSON.dump({:ack => "uuid"})
        end

        it "presents JSON-decoded event to the specified handler" do
          event = nil
          @client.send(:connect, @routing_keys) { |e| event = e }
          @websocket.onmessage(@json_event)
          event.should == @event
        end

        it "logs event" do
          @log.should_receive(:info).with("Creating WebSocket connection to ws://test.com/connect").once.ordered
          @log.should_receive(:info).with("Received EVENT <uuid> Push /foo/bar from rs-agent-1-1").once.ordered
          event = nil
          @client.send(:connect, @routing_keys) { |e| event = e }
          @websocket.onmessage(@json_event)
          event.should == @event
        end

        it "acknowledges event" do
          @client.send(:connect, @routing_keys) { |_| nil }
          @websocket.onmessage(@json_event)
          @websocket.sent.should == @json_ack
        end

        it "logs failures" do
          @log.should_receive(:error).with("Failed handling WebSocket event", StandardError, :trace).once
          request = RightScale::Request.new("/foo/bar", "payload")
          @client.send(:connect, @routing_keys) { |_| raise StandardError, "bad event" }
          @websocket.onmessage(JSON.dump(request))
        end
      end

      context "on close" do
        it "logs info" do
          @log.should_receive(:info).with("Creating WebSocket connection to ws://test.com/connect").once.ordered
          @log.should_receive(:info).with("WebSocket closed (1000)").once.ordered
          @client.send(:connect, @routing_keys, &@handler)
          @websocket.onclose(1000)
          @client.instance_variable_get(:@websocket).should be nil
        end

        it "logged info includes reason if available" do
          @log.should_receive(:info).with("Creating WebSocket connection to ws://test.com/connect").once.ordered
          @log.should_receive(:info).with("WebSocket closed (1001: Going Away)").once.ordered
          @client.send(:connect, @routing_keys, &@handler)
          @websocket.onclose(1001, "Going Away")
        end

        it "logs unexpected exceptions" do
          @log.should_receive(:info).with("Creating WebSocket connection to ws://test.com/connect").once.ordered
          @log.should_receive(:info).and_raise(RuntimeError).once.ordered
          @log.should_receive(:error).with("Failed closing WebSocket", RuntimeError, :trace).once
          @client.send(:connect, @routing_keys, &@handler)
          @websocket.onclose(1000)
        end
      end

      context "on error" do
        ["0.7.0", "0.7.4"].each do |version|
          context "in faye-websocket #{version}" do
            before(:each) do
              @websocket = WebSocketClientMock.new(version)
              flexmock(Faye::WebSocket::Client).should_receive(:new).and_return(@websocket)
            end

            it "logs error" do
              @log.should_receive(:error).with("WebSocket error (Protocol Error)")
              @client.send(:connect, @routing_keys, &@handler)
              @websocket.onerror("Protocol Error")
            end

            it "does not log if there is no error data" do
              @log.should_receive(:error).never
              @client.send(:connect, @routing_keys, &@handler)
              @websocket.onerror(nil)
            end
          end
        end
      end
    end

    context :try_long_poll do
      before(:each) do
        @event_uuids = ["uuid"]
        @client.instance_variable_set(:@connect_interval, 30)
        @client.instance_variable_set(:@reconnect_interval, 2)
      end

      it "makes long-polling request" do
        flexmock(@client).should_receive(:long_poll).with(@routing_keys, @event_uuids, @handler).and_return([]).once
        @client.send(:try_long_poll, @routing_keys, @event_uuids, &@handler).should == []
      end

      it "returns UUIDs of events received" do
        flexmock(@client).should_receive(:long_poll).with(@routing_keys, [], @handler).and_return { @event_uuids }.once
        @client.send(:try_long_poll, @routing_keys, [], &@handler).should == @event_uuids
      end

      it "returns exception if there is a long-polling failure" do
        flexmock(@client).should_receive(:long_poll).and_raise(RuntimeError).once
        @client.send(:try_long_poll, @routing_keys, @event_uuids, &@handler).should be_a RuntimeError
      end
    end

    context :try_deferred_long_poll do
      before(:each) do
        @event_uuids = ["uuid"]
        @client.instance_variable_set(:@connect_interval, 30)
        @client.instance_variable_set(:@reconnect_interval, 2)
        @client.send(:update_listen_state, :long_poll)
        flexmock(EM).should_receive(:defer).by_default
      end

      it "makes long-polling request using defer thread" do
        flexmock(EM).should_receive(:defer).with(Proc, Proc).once
        @client.send(:try_deferred_long_poll, @routing_keys, @event_uuids, &@handler).should be true
      end

      context "defer_operation_proc" do
        it "long-polls" do
          @client.instance_variable_set(:@connect_interval, 1)
          @client.send(:try_deferred_long_poll, @routing_keys, @event_uuids, &@handler)
          @defer_operation_proc = @client.instance_variable_get(:@defer_operation_proc)
          flexmock(@client).should_receive(:long_poll).with(@routing_keys, @event_uuids, @handler).and_return([]).once
          @defer_operation_proc.call.should == []
        end
      end

      context "defer_callback_proc" do
        before(:each) do
          @client.instance_variable_set(:@connect_interval, 1)
          @client.send(:try_deferred_long_poll, @routing_keys, @event_uuids, &@handler)
          @defer_callback_proc = @client.instance_variable_get(:@defer_callback_proc)
        end

        it "handles UUIDs of events received" do
          @defer_callback_proc.call(@event_uuids).should == @event_uuids
          @client.instance_variable_get(:@event_uuids).should == @event_uuids
          @client.instance_variable_get(:@listen_state).should == :choose
          @client.instance_variable_get(:@listen_interval).should == 0
        end

        it "handles exception if there is a long-polling failure" do
          @defer_callback_proc.call(RuntimeError.new).should be nil
          @client.instance_variable_get(:@listen_state).should == :choose
          @client.instance_variable_get(:@listen_interval).should == 4
        end
      end
    end

    context :long_poll do
      before(:each) do
        @ack = []
      end

      it "raises if block missing" do
        lambda { @client.send(:long_poll, @routing_keys, @ack) }.should raise_error(ArgumentError, "Block missing")
      end

      it "makes listen request to router" do
        flexmock(@client).should_receive(:make_request).with(:poll, "/listen",
            on { |a| a[:wait_time].should == 55 && !a.key?(:routing_keys) &&
            a[:timestamp] == @later.to_f }, "listen", Hash).and_return([@event]).once
        @client.send(:long_poll, @routing_keys, @ack, &@handler)
      end

      it "uses listen timeout for request poll timeout and connect interval for request timeout" do
        @client.instance_variable_set(:@connect_interval, 300)
        flexmock(@client).should_receive(:make_request).with(:poll, "/listen", Hash, "listen",
            {:poll_timeout => 60, :request_timeout => 300}).and_return([@event]).once
        @client.send(:long_poll, @routing_keys, @ack, &@handler)
      end

      it "logs event" do
        @log.should_receive(:info).with("Received EVENT <uuid> Push /foo/bar from rs-agent-1-1").once
        flexmock(@client).should_receive(:make_request).and_return([@event])
        @client.send(:long_poll, @routing_keys, @ack, &@handler)
      end

      it "presents event to handler" do
        flexmock(@client).should_receive(:make_request).and_return([@event])
        event = nil
        @client.send(:long_poll, @routing_keys, @ack) { |e| event = e }
        event.should == @event
      end

      it "handles event keys that are strings" do
        event = {"uuid" => "uuid", "type" => "Push", "path" => "/foo/bar", "from" => "rs-agent-1-1", "data" => {}, "version" => @version}
        @log.should_receive(:info).with("Received EVENT <uuid> Push /foo/bar from rs-agent-1-1").once
        flexmock(@client).should_receive(:make_request).and_return([event])
        event = nil
        @client.send(:long_poll, @routing_keys, @ack) { |e| event = e }
        event.should == @event
      end

      it "does nothing if no events are returned" do
        flexmock(@client).should_receive(:make_request).and_return(nil)
        event = nil
        @client.send(:long_poll, @routing_keys, @ack) { |e| event = e }
        event.should be nil
      end

      it "returns event UUIDs" do
        flexmock(@client).should_receive(:make_request).and_return([@event])
        @client.send(:long_poll, @routing_keys, @ack, &@handler).should == ["uuid"]
       end

      it "returns nil if no events are received" do
        flexmock(@client).should_receive(:make_request).and_return(nil)
        @client.send(:long_poll, @routing_keys, @ack, &@handler).should be nil
      end
    end

    context :process_long_poll do
      before(:each) do
        @event_uuids = ["uuid"]
        @client.instance_variable_set(:@connect_interval, 30)
        @client.instance_variable_set(:@reconnect_interval, 2)
        @client.send(:update_listen_state, :long_poll)
      end

      [RightScale::Exceptions::Unauthorized.new("error"),
       RightScale::Exceptions::ConnectivityFailure.new("error"),
       RightScale::Exceptions::RetryableError.new("error"),
       RightScale::Exceptions::InternalServerError.new("error", "server")].each do |e|
        it "does not trace #{e} exceptions but sets state to :choose" do
          @client.send(:process_long_poll, e).should be nil
          @client.instance_variable_get(:@listen_state).should == :choose
          @client.instance_variable_get(:@listen_interval).should == 4
          @client.instance_variable_get(:@connect_interval).should == 30
        end
      end

      it "traces unexpected exceptions and sets state to :choose" do
        e = RuntimeError.new
        @client.send(:process_long_poll, e).should be nil
        @client.instance_variable_get(:@listen_state).should == :choose
        @client.instance_variable_get(:@listen_interval).should == 4
      end

      context "when no exception" do
        it "sets state to :choose" do
          @client.instance_variable_set(:@reconnect_interval, 2)
          @client.send(:process_long_poll, @event_uuids).should == @event_uuids
          @client.instance_variable_get(:@listen_state).should == :choose
          @client.instance_variable_get(:@reconnect_interval).should == 2
          @client.instance_variable_get(:@listen_interval).should == 0
        end
      end
    end

    context :backoff_connect_interval do
      it "backs off exponentially" do
        @client.instance_variable_set(:@connect_interval, 30)
        @client.send(:backoff_connect_interval).should == 60
        @client.send(:backoff_connect_interval).should == 120
      end

      it "limits backoff" do
        @client.instance_variable_set(:@connect_interval, 30)
        12.times { @client.send(:backoff_connect_interval) }
        @client.instance_variable_get(:@connect_interval).should == RightScale::RouterClient::MAX_CONNECT_INTERVAL
      end
    end

    context :backoff_reconnect_interval do
      it "backs off exponentially" do
        @client.instance_variable_set(:@reconnect_interval, 2)
        @client.send(:backoff_reconnect_interval).should == 4
        @client.send(:backoff_reconnect_interval).should == 8
      end

      it "limits backoff" do
        @client.instance_variable_set(:@reconnect_interval, 2)
        6.times { @client.send(:backoff_reconnect_interval) }
        @client.instance_variable_get(:@reconnect_interval).should == RightScale::RouterClient::MAX_RECONNECT_INTERVAL
      end
    end

    context :router_not_responding? do
      [502, 503].each do |code|
        it "declares not responding if have close reason code #{code} indicating router inaccessible" do
          @client.instance_variable_set(:@close_code, RightScale::RouterClient::PROTOCOL_ERROR_CLOSE)
          @client.instance_variable_set(:@close_reason, "Unexpected response code: #{code}")
          @client.send(:router_not_responding?).should be_true
        end
      end

      it "does not declare not responding for other close codes" do
        @client.instance_variable_set(:@close_code, RightScale::RouterClient::UNEXPECTED_ERROR_CLOSE)
        @client.instance_variable_set(:@close_reason, "Unexpected response code: 502")
        @client.send(:router_not_responding?).should be false
      end
    end
  end
end