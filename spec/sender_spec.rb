#
# Copyright (c) 2009-2013 RightScale Inc
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

require File.expand_path(File.join(File.dirname(__FILE__), 'spec_helper'))

describe RightScale::Sender do

  include FlexMock::ArgumentTypes

  context "access instance" do
    before do
      RightScale::Sender.class_eval do
        remove_class_variable(:@@instance) if class_variable_defined?(:@@instance)
      end
    end

    it "returns nil when the instance is undefined" do
      RightScale::Sender.instance.should == nil
    end

    it "returns the instance if defined" do
      RightScale::Sender.class_eval { @@instance = "instance" }
      RightScale::Sender.instance.should_not == nil
    end
  end

  context "use instance" do
    # Create new sender with specified mode and options
    # Also create mock agent and client for it with basic support for both modes
    def create_sender(mode, options = {})
      @broker_id = "rs-broker-1-1"
      @broker_ids = [@broker_id]
      @client = flexmock("client", :push => true, :request => true, :all => @broker_ids, :publish => @broker_ids).by_default
      @agent_id = "rs-agent-1-1"
      @agent = flexmock("agent", :identity => @agent_id, :client => @client, :mode => mode, :request_queue => "request",
                        :options => options).by_default
      RightScale::Sender.new(@agent)
      RightScale::Sender.instance
    end

    before(:each) do
      @log = flexmock(RightScale::Log)
      @log.should_receive(:error).by_default.and_return { |m| raise RightScale::Log.format(*m) }
      @log.should_receive(:warning).by_default.and_return { |m| raise RightScale::Log.format(*m) }
      @sender = create_sender(:http)
      @token = "token"
      @ttl = 30
      @type = "/foo/bar"
      @action = "bar"
      @payload = {:pay => "load"}
      @target = "target"
      @options = {}
      @response = nil
      @callback = lambda { |response| @response = response }
      @now = Time.now
      flexmock(Time).should_receive(:now).and_return(@now).by_default
      @received_at = @now
    end

    context :initialize do
      it "creates connectivity checker if mode is amqp" do
        @sender = create_sender(:amqp)
        @sender.connectivity_checker.should be_a(RightScale::ConnectivityChecker)
      end
    end

    context "offline handling" do

      context :initialize_offline_queue do
        it "initializes offline handler" do
          @sender = create_sender(:amqp, :offline_queueing => true)
          flexmock(@sender.offline_handler).should_receive(:init).once
          @sender.initialize_offline_queue
        end

        it "does nothing if offline queueing is disabled" do
          flexmock(@sender.offline_handler).should_receive(:init).never
          @sender.initialize_offline_queue
        end
      end

      context :start_offline_queue do
        it "starts offline handler" do
          @sender = create_sender(:amqp, :offline_queueing => true)
          flexmock(@sender.offline_handler).should_receive(:start).once
          @sender.start_offline_queue
        end

        it "does nothing if offline queueing is disabled" do
          flexmock(@sender.offline_handler).should_receive(:start).never
          @sender.start_offline_queue
        end
      end

      context :enable_offline_mode do
       it "enables offline handler" do
          @sender = create_sender(:amqp, :offline_queueing => true)
          flexmock(@sender.offline_handler).should_receive(:enable).once
          @sender.enable_offline_mode
        end

        it "does nothing if offline queueing is disabled" do
          flexmock(@sender.offline_handler).should_receive(:enable).never
          @sender.enable_offline_mode
        end
      end

      context :disable_offline_mode do
        it "initializes offline handler" do
          @sender = create_sender(:amqp, :offline_queueing => true)
          flexmock(@sender.offline_handler).should_receive(:disable).once
          @sender.disable_offline_mode
        end

        it "does nothing if offline queueing is disabled" do
          flexmock(@sender.offline_handler).should_receive(:disable).never
          @sender.disable_offline_mode
        end
      end
    end

    context :send_push do
      it "creates Push object" do
        flexmock(RightSupport::Data::UUID, :generate => "random token")
        flexmock(@sender).should_receive(:http_send).with(:send_push, nil, on { |a| a.class == RightScale::Push &&
            a.type == @type && a.from == @agent_id && a.target.nil? && a.persistent == true && a.confirm.nil? &&
            a.token == "random token" && a.expires_at == 0 }, Time).once
        @sender.send_push(@type).should be_true
      end

      it "stores payload" do
        flexmock(@sender).should_receive(:http_send).with(:send_push, nil, on { |a| a.payload == @payload }, Time).once
        @sender.send_push(@type, @payload).should be_true
      end

      it "sets specific target using string" do
        flexmock(@sender).should_receive(:http_send).with(:send_push, @target, on { |a| a.target == @target &&
            a.selector == :any }, Time).once
        @sender.send_push(@type, nil, @target).should be_true
      end

      it "sets specific target using :agent_id" do
        target = {:agent_id => @agent_id}
        flexmock(@sender).should_receive(:http_send).with(:send_push, target, on { |a| a.target == @agent_id }, Time).once
        @sender.send_push(@type, nil, target).should be_true
      end

      it "sets target tags" do
        tags = ["a:b=c"]
        target = {:tags => tags}
        flexmock(@sender).should_receive(:http_send).with(:send_push, target, on { |a| a.tags == tags &&
            a.selector == :any }, Time).once
        @sender.send_push(@type, nil, target).should be_true
      end

      it "sets target scope" do
        scope = {:shard => 1, :account => 123}
        target = {:scope => scope}
        flexmock(@sender).should_receive(:http_send).with(:send_push, target, on { |a| a.scope == scope &&
            a.selector == :any }, Time).once
        @sender.send_push(@type, nil, target).should be_true
      end

      it "sets target selector" do
        tags = ["a:b=c"]
        target = {:tags => tags, :selector => :all}
        flexmock(@sender).should_receive(:http_send).with(:send_push, target, on { |a| a.selector == :all }, Time).once
        @sender.send_push(@type, nil, target).should be_true
      end

      it "sets token" do
        flexmock(@sender).should_receive(:http_send).with(:send_push, @target, on { |a| a.token == "token2" }, Time).once
        @sender.send_push(@type, nil, @target, :token => "token2").should be_true
      end

      it "defaults to no expiration time" do
        @sender = create_sender(:http, :time_to_live => 99)
        flexmock(@sender).should_receive(:http_send).with(:send_push, nil, on { |a| a.expires_at == 0 }, Time).once
        @sender.send_push(@type).should be_true
      end

      it "sets expiration time if time-to-live if specified" do
        flexmock(@sender).should_receive(:http_send).with(:send_push, @target, on { |a| a.expires_at == (@now + @ttl).to_i }, Time).once
        @sender.send_push(@type, nil, @target, :time_to_live => @ttl).should be_true
      end

      it "sets applies callback for returning response" do
        flexmock(@sender).should_receive(:http_send).with(:send_push, nil, on { |a| a.confirm == true }, Time, Proc).once
        @sender.send_push(@type) { |_| }.should be_true
      end
    end

    context :send_request do
      it "creates Request object" do
        flexmock(RightSupport::Data::UUID, :generate => "random token")
        flexmock(@sender).should_receive(:http_send).with(:send_request, nil, on { |a| a.class == RightScale::Request &&
            a.type == @type && a.from == @agent_id && a.target.nil? && a.persistent.nil? && a.selector == :any &&
            a.token == "random token" && a.expires_at == 0 }, Time, Proc).once
        @sender.send_request(@type) { |_| }.should be_true
      end

      it "stores payload" do
        flexmock(@sender).should_receive(:http_send).with(:send_request, nil, on { |a| a.payload == @payload }, Time, Proc)
        @sender.send_request(@type, @payload) { |_| }.should be_true
      end

      it "sets specific target using string" do
        flexmock(@sender).should_receive(:http_send).with(:send_request, @agent_id, on { |a| a.target == @agent_id &&
            a.selector == :any }, Time, Proc).once
        @sender.send_request(@type, nil, @agent_id) { |_| }.should be_true
      end

      it "sets specific target using :agent_id" do
        target = {:agent_id => @agent_id}
        flexmock(@sender).should_receive(:http_send).with(:send_request, target, on { |a| a.target == @agent_id }, Time, Proc).once
        @sender.send_request(@type, nil, target) { |_| }.should be_true
      end

      it "sets target tags" do
        tags = ["a:b=c"]
        target = {:tags => tags}
        flexmock(@sender).should_receive(:http_send).with(:send_request, target, on { |a| a.tags == tags &&
            a.selector == :any }, Time, Proc).once
        @sender.send_request(@type, nil, target) { |_| }.should be_true
      end

      it "sets target scope" do
        scope = {:shard => 1, :account => 123}
        target = {:scope => scope}
        flexmock(@sender).should_receive(:http_send).with(:send_request, target, on { |a| a.scope == scope &&
            a.selector == :any }, Time, Proc).once
        @sender.send_request(@type, nil, target) { |_| }.should be_true
      end

      it "sets token" do
        flexmock(@sender).should_receive(:http_send).with(:send_request, @target, on { |a| a.token == "token2" }, Time, Proc).once
        @sender.send_request(@type, nil, @target, :token => "token2") { |_| }.should be_true
      end

      it "sets expiration time if time-to-live configured" do
        @sender = create_sender(:http, :time_to_live => 99)
        flexmock(@sender).should_receive(:http_send).with(:send_request, nil, on { |a| a.expires_at == (@now + 99).to_i }, Time, Proc).once
        @sender.send_request(@type) { |_| }.should be_true
      end

      it "overrides configured time-to-live with specified time-to-live" do
        @sender = create_sender(:http, :time_to_live => 99)
        flexmock(@sender).should_receive(:http_send).with(:send_request, @target, on { |a| a.expires_at == (@now + @ttl).to_i }, Time, Proc).once
        @sender.send_request(@type, nil, @target, :time_to_live => @ttl) { |_| }.should be_true
      end

      it "does not allow fanout" do
        lambda { @sender.send_request(@type, nil, :selector => :all) }.should raise_error(ArgumentError)
      end

      it "requires callback block" do
        lambda { @sender.send_request(@type) }.should raise_error(ArgumentError)
      end
    end

    context :build_and_send_packet do
      [:http, :amqp].each do |mode|
        context "when #{mode}" do
          before(:each) do
            @sender = create_sender(mode)
          end

          [[:send_push, RightScale::Push, nil], [:send_request, RightScale::Request, @callback]].each do |kind, klass, callback|
            it "builds packet" do
              packet = flexmock("packet", :type => @type, :token => @token, :selector => :any)
              flexmock(@sender).should_receive(:build_packet).
                  with(kind, @type, @payload, @target, @options, &callback).and_return(packet).once
              flexmock(@sender).should_receive("#{mode}_send".to_sym)
              @sender.build_and_send_packet(kind, @type, @payload, @target, @options, &callback).should be_true
            end

            it "sends packet" do
              flexmock(@sender).should_receive("#{mode}_send".to_sym).
                  with(kind, @target, on { |a| a.class == klass }, Time, &callback).once
              @sender.build_and_send_packet(kind, @type, @payload, @target, @options, &callback).should be_true
            end

            it "ignores nil packet result when queueing" do
              flexmock(@sender).should_receive(:build_packet).
                  with(kind, @type, @payload, @target, @options, &callback).and_return(nil).once
              flexmock(@sender).should_receive("#{mode}_send".to_sym).never
              @sender.build_and_send_packet(kind, @type, @payload, @target, @options, &callback).should be_true
            end
          end
        end
      end
    end

    context :build_packet do
      [:send_push, :send_request].each do |kind|
        context "when #{kind}" do
          it "validates target" do
            flexmock(@sender).should_receive(:validate_target).with(@target, kind == :send_push).once
            @sender.build_packet(kind, @type, nil, @target).should_not be_nil
          end

          it "submits request to offline handler and returns nil if queueing" do
            flexmock(@sender).should_receive(:queueing?).and_return(true).once
            @sender.build_packet(kind, @type, nil, @target).should be_nil
          end

          it "uses specified request token" do
            flexmock(RightSupport::Data::UUID, :generate => "random token")
            packet = @sender.build_packet(kind, @type, nil, @target, :token => @token)
            packet.token.should == @token
          end

          it "generates a request token if none provided" do
            flexmock(RightSupport::Data::UUID, :generate => "random token")
            packet = @sender.build_packet(kind, @type, nil, @target)
            packet.token.should == "random token"
          end

          it "sets payload" do
            packet = @sender.build_packet(kind, @type, @payload, @target)
            packet.payload.should == @payload
          end

          it "sets the packet from this agent" do
            packet = @sender.build_packet(kind, @type, nil, @target)
            packet.from.should == @agent_id
          end

          it "sets target if target is not a hash" do
            packet = @sender.build_packet(kind, @type, nil, @target)
            packet.target.should == @target
          end

          context "when target is a hash" do
            it "sets agent ID" do
              target = {:agent_id => @agent_id}
              packet = @sender.build_packet(kind, @type, nil, target)
              packet.target.should == @agent_id
            end

            it "sets tags" do
              tags = ["a:b=c"]
              target = {:tags => tags}
              packet = @sender.build_packet(kind, @type, nil, target)
              packet.tags.should == tags
              packet.scope.should be_nil
            end

            it "sets scope" do
              scope = {:shard => 1, :account => 123}
              target = {:scope => scope}
              packet = @sender.build_packet(kind, @type, nil, target)
              packet.tags.should == []
            end
          end

          if kind == :send_push
            it "defaults selector to :any" do
              packet = @sender.build_packet(kind, @type, nil, @target)
              packet.selector.should == :any
            end

            it "sets selector" do
              target = {:selector => :all}
              packet = @sender.build_packet(kind, @type, nil, target)
              packet.selector.should == :all
            end

            it "sets persistent flag" do
              packet = @sender.build_packet(kind, @type, nil, @target)
              packet.persistent.should be_true
            end

            it "enables confirm if callback provided" do
              packet = @sender.build_packet(kind, @type, nil, @target, &@callback)
              packet.confirm.should be_true
            end

            it "does not enable confirm if not callback provided" do
              packet = @sender.build_packet(kind, @type, nil, @target)
              packet.confirm.should be_false
            end

            it "does not set expiration time by default" do
              @sender = create_sender(:http, :time_to_live => 99)
              packet = @sender.build_packet(kind, @type, nil, @target)
              packet.expires_at.should == 0
            end

            it "sets expiration time if specified" do
              packet = @sender.build_packet(kind, @type, nil, @target, :time_to_live => @ttl)
              packet.expires_at.should == (@now + @ttl).to_i
            end
          else
            it "always sets selector to :any" do
              packet = @sender.build_packet(kind, @type, nil, @target)
              packet.selector.should == :any
            end

            it "sets expiration time to specified time-to-live" do
              packet = @sender.build_packet(kind, @type, nil, @target, :time_to_live => @ttl)
              packet.expires_at.should == (@now + @ttl).to_i
            end
          end

          it "queues request if currently queuing and returns nil" do
            @options = {:token => @token, :time_to_live => @ttl}
            @sender = create_sender(:http, :offline_queueing => true)
            flexmock(@sender.offline_handler).should_receive(:queueing?).and_return(true)
            flexmock(@sender.offline_handler).should_receive(:queue_request).
                with(kind, @type, @payload, @target, @token, (@now + @ttl).to_i, 0, @callback).once
            @sender.build_packet(kind, @type, @payload, @target, @options, &@callback).should be nil
          end
        end
      end
    end

    context :handle_response do
      before(:each) do
        flexmock(RightSupport::Data::UUID, :generate => @token)
        @pending_request = RightScale::PendingRequest.new(:send_request, @received_at, @callback)
        @sender.pending_requests[@token] = @pending_request
      end

      [:send_push, :send_request].each do |kind|
        it "delivers the response for a #{kind}" do
          @pending_request = RightScale::PendingRequest.new(kind, @received_at, @callback)
          @sender.pending_requests[@token] = @pending_request
          response = RightScale::Result.new(@token, "to", RightScale::OperationResult.success, @target)
          flexmock(@sender).should_receive(:deliver_response).with(response, @pending_request).once
          @sender.handle_response(response).should be_true
        end
      end

      it "logs a debug message if request no longer pending" do
        @sender.pending_requests.delete(@token)
        @log.should_receive(:debug).with(/No pending request for response/).once
        response = RightScale::Result.new(@token, "to", RightScale::OperationResult.success, @target)
        @sender.handle_response(response)
      end

      it "ignores responses that are not a Result" do
        flexmock(@sender).should_receive(:deliver_response).never
        @sender.handle_response("response").should be_true
      end

      context "when non-delivery" do
        before(:each) do
          @reason = RightScale::OperationResult::TARGET_NOT_CONNECTED
          non_delivery = RightScale::OperationResult.non_delivery(@reason)
          @response = RightScale::Result.new(@token, "to", non_delivery, @target)
        end

        it "records non-delivery regardless of whether there is a pending request" do
          @sender.pending_requests.delete(@token)
          non_delivery = RightScale::OperationResult.non_delivery(RightScale::OperationResult::NO_ROUTE_TO_TARGET)
          response = RightScale::Result.new(@token, "to", non_delivery, @target)
          @sender.handle_response(response).should be_true
          @sender.instance_variable_get(:@non_delivery_stats).total.should == 1
        end

        it "logs non-delivery if there is no pending request" do
          @sender.pending_requests.delete(@token)
          @log.should_receive(:info).with(/Non-delivery of/).once
          non_delivery = RightScale::OperationResult.non_delivery(RightScale::OperationResult::NO_ROUTE_TO_TARGET)
          response = RightScale::Result.new(@token, "to", non_delivery, @target)
          @sender.handle_response(response).should be_true
        end

        context "for a Request" do

          context "with target not connected" do
            it "logs non-delivery but does not deliver it" do
              @log.should_receive(:info).with(/Non-delivery of/).once
              flexmock(@sender).should_receive(:deliver_response).never
              @sender.handle_response(@response).should be_true
            end

            it "records non-delivery reason in pending request if for parent request" do
              @log.should_receive(:info).with(/Non-delivery of/).once
              flexmock(@sender).should_receive(:deliver_response).never
              parent_token = "parent token"
              parent_pending_request = RightScale::PendingRequest.new(:send_request, @received_at, @callback)
              @sender.pending_requests[parent_token] = parent_pending_request
              @pending_request.retry_parent_token = parent_token
              @sender.handle_response(@response).should be_true
              parent_pending_request.non_delivery.should == @reason
            end

            it "updates non-delivery reason if for retry request" do
              flexmock(@sender).should_receive(:deliver_response).never
              @sender.handle_response(@response).should be_true
              @pending_request.non_delivery.should == @reason
            end
          end

          context "with retry timeout and previous non-delivery" do
            it "delivers response using stored non-delivery reason" do
              @reason = RightScale::OperationResult::RETRY_TIMEOUT
              @response.results = RightScale::OperationResult.non_delivery(@reason)
              @pending_request.non_delivery = "other reason"
              flexmock(@sender).should_receive(:deliver_response).with(on { |a| a.results.content == "other reason"},
                  @pending_request).once
              @sender.handle_response(@response).should be_true
            end
          end

          context "otherwise" do
            it "delivers non-delivery response as is" do
              @response.results = RightScale::OperationResult.non_delivery("other")
              flexmock(@sender).should_receive(:deliver_response).with(on { |a| a.results.content == "other"},
                  RightScale::PendingRequest).once
              @sender.handle_response(@response).should be_true
            end
          end
        end
      end
    end

    context :terminate do
      it "terminates offline handler" do
        flexmock(@sender.offline_handler).should_receive(:terminate).once
        @sender.terminate
      end

      it "terminates connectivity checker if configured" do
        @sender = create_sender(:amqp, :offline_queueing => true)
        flexmock(@sender.connectivity_checker).should_receive(:terminate).once
        @sender.terminate
      end

      it "returns number of pending requests and age of youngest request" do
        receive_time = Time.now - 10
        @sender.pending_requests[@token] = RightScale::PendingRequest.new(:send_request, receive_time, @callback)
        @sender.terminate.should == [1, 10]
      end
    end

    context :dump_requests do
      it "returns array of unfinished non-push requests" do
        time1 = Time.now
        @sender.pending_requests["token1"] = RightScale::PendingRequest.new(:send_push, time1, @callback)
        time2 = time1 + 10
        @sender.pending_requests["token2"] = RightScale::PendingRequest.new(:send_request, time2, @callback)
        @sender.dump_requests.should == ["#{time2.localtime} <token2>"]
      end

      it "returns requests in descending time order" do
        time1 = Time.now
        @sender.pending_requests["token1"] = RightScale::PendingRequest.new(:send_request, time1, @callback)
        time2 = time1 + 10
        @sender.pending_requests["token2"] = RightScale::PendingRequest.new(:send_request, time2, @callback)
        @sender.dump_requests.should == ["#{time2.localtime} <token2>", "#{time1.localtime} <token1>"]
      end

      it "limits the number returned to 50" do
        pending_request = RightScale::PendingRequest.new(:send_request, Time.now, @callback)
        55.times.each { |i| @sender.pending_requests["token#{i}"] = pending_request }
        result = @sender.dump_requests
        result.size.should == 51
        result.last.should == "..."
      end
    end

    context :validate_target do
      it "should accept nil target" do
        @sender.send(:validate_target, nil, true).should be_true
      end

      it "should accept named target" do
        @sender.send(:validate_target, "name", true).should be_true
      end

      context "when target is a hash" do

        context "and agent ID is specified" do
          it "should not allow other keys" do
            @sender.send(:validate_target, {:agent_id => @agent_id}, true).should be_true
            lambda { @sender.send(:validate_target, {:agent_id => @agent_id, :tags => ["a:b=c"]}, true) }.should \
              raise_error(ArgumentError, /Invalid target/)
          end
        end

        context "and selector is allowed" do
          it "should accept :all or :any selector" do
            @sender.send(:validate_target, {:selector => :all}, true).should be_true
            @sender.send(:validate_target, {"selector" => "any"}, true).should be_true
          end

          it "should reject values other than :all or :any" do
            lambda { @sender.send(:validate_target, {:selector => :other}, true) }.
                should raise_error(ArgumentError, /Invalid target selector/)
          end
        end

        context "and selector is not allowed" do
          it "should reject selector" do
            lambda { @sender.send(:validate_target, {:selector => :all}, false) }.
                should raise_error(ArgumentError, /Invalid target hash/)
          end
        end

        context "and tags is specified" do
          it "should accept tags" do
            @sender.send(:validate_target, {:tags => []}, true).should be_true
            @sender.send(:validate_target, {"tags" => ["tag"]}, true).should be_true
          end

          it "should reject non-array" do
            lambda { @sender.send(:validate_target, {:tags => {}}, true) }.
                should raise_error(ArgumentError, /Invalid target tags/)
          end
        end

        context "and scope is specified" do
          it "should accept account" do
            @sender.send(:validate_target, {:scope => {:account => 1}}, true).should be_true
            @sender.send(:validate_target, {"scope" => {"account" => 1}}, true).should be_true
          end

          it "should accept shard" do
            @sender.send(:validate_target, {:scope => {:shard => 1}}, true).should be_true
            @sender.send(:validate_target, {"scope" => {"shard" => 1}}, true).should be_true
          end

          it "should accept account and shard" do
            @sender.send(:validate_target, {"scope" => {:shard => 1, "account" => 1}}, true).should be_true
          end

          it "should reject keys other than account and shard" do
            target = {"scope" => {:shard => 1, "account" => 1, :other => 2}}
            lambda { @sender.send(:validate_target, target, true) }.
                should raise_error(ArgumentError, /Invalid target scope/)
          end

          it "should reject empty hash" do
            lambda { @sender.send(:validate_target, {:scope => {}}, true) }.
                should raise_error(ArgumentError, /Invalid target scope/)
          end
        end

        context "and multiple are specified" do
          it "should accept scope and tags" do
            @sender.send(:validate_target, {:scope => {:shard => 1}, :tags => []}, true).should be_true
          end

          it "should accept scope, tags, and selector" do
            target = {:scope => {:shard => 1}, :tags => ["tag"], :selector => :all}
            @sender.send(:validate_target, target, true).should be_true
          end

          it "should reject selector if not allowed" do
            target = {:scope => {:shard => 1}, :tags => ["tag"], :selector => :all}
            lambda { @sender.send(:validate_target, target, false) }.
                should raise_error(ArgumentError, /Invalid target hash/)
          end
        end

        it "should reject keys other than selector, scope, and tags" do
          target = {:scope => {:shard => 1}, :tags => [], :selector => :all, :other => 2}
          lambda { @sender.send(:validate_target, target, true) }.
              should raise_error(ArgumentError, /Invalid target hash/)
        end

        it "should reject empty hash" do
          lambda { @sender.send(:validate_target, {}, true) }.
              should raise_error(ArgumentError, /Invalid target hash/)
        end

        it "should reject value that is not nil, string, or hash" do
          lambda { @sender.send(:validate_target, [], true) }.
              should raise_error(ArgumentError, /Invalid target/)
        end
      end
    end

    context :http do

      context :http_send do
        before(:each) do
          @token = "random token"
          flexmock(RightSupport::Data::UUID).should_receive(:generate).and_return(@token).by_default
          @packet = @sender.build_packet(:send_request, @type, @payload, @target, @options, &@callback)
        end

        it "sends request using configured client" do
          @packet = @sender.build_packet(:send_push, @type, @payload, @target, @options, &@callback)
          @client.should_receive(:push).with(@type, @payload, @target, :request_uuid => @token).and_return(nil).once
          @sender.send(:http_send, :send_push, @target, @packet, @received_at, &@callback).should be_true
        end

        context "when :async_response enabled" do
          before(:each) do
            @sender = create_sender(:http, :async_response => true)
            flexmock(EM).should_receive(:next_tick).and_yield.once
          end

          it "sends in next_tick if :async_response option set" do
            @packet = @sender.build_packet(:send_push, @type, @payload, @target, @options, &@callback)
            @client.should_receive(:push).with(@type, @payload, @target, :request_uuid => @token).and_return(nil).once
            @sender.send(:http_send, :send_push, @target, @packet, @received_at, &@callback).should be_true
          end

          it "logs unexpected exception" do
            flexmock(@sender).should_receive(:handle_response).and_raise(RuntimeError).once
            @log.should_receive(:error).with(/Failed sending or handling response/, RuntimeError, :trace).once
            @packet = @sender.build_packet(:send_request, @type, @payload, @target, @options, &@callback)
            @client.should_receive(:request).with(@type, @payload, @target, :request_uuid => @token).and_return("result").once
            @sender.send(:http_send, :send_request, @target, @packet, @received_at, &@callback).should be_true
          end
        end
      end

      context :http_send_once do
        before(:each) do
          @token = "random token"
          flexmock(RightSupport::Data::UUID).should_receive(:generate).and_return(@token).by_default
          @packet = @sender.build_packet(:send_request, @type, @payload, @target, @options, &@callback)
        end

        it "sends request using configured client" do
          @packet = @sender.build_packet(:send_push, @type, @payload, @target)
          @client.should_receive(:push).with(@type, @payload, @target, :request_uuid => @token).and_return(nil).once
          @sender.send(:http_send_once, :send_push, @target, @packet, @received_at).should be_true
        end

        it "sends request with time-to-live to configured client" do
          @packet = @sender.build_packet(:send_push, @type, @payload, @target, @options, &@callback)
          @client.should_receive(:push).with(@type, @payload, @target, :request_uuid => @token).and_return(nil).once
          @sender.send(:http_send_once, :send_request, @target, @packet, @received_at, &@callback).should be_true
        end

        it "responds with success result containing response" do
          @client.should_receive(:request).with(@type, @payload, @target, :request_uuid => @token).and_return("result").once
          @sender.send(:http_send_once, :send_request, @target, @packet, @received_at, &@callback).should be_true
          @response.token.should == @token
          @response.results.success?.should be_true
          @response.results.content.should == "result"
          @response.from.should == @target
          @response.received_at.should == @received_at.to_f
        end

        it "responds with success result when response is nil" do
          @client.should_receive(:request).with(@type, @payload, @target, :request_uuid => @token).and_return(nil).once
          @sender.send(:http_send_once, :send_request, @target, @packet, @received_at, &@callback).should be_true
          @response.token.should == @token
          @response.results.success?.should be_true
          @response.results.content.should be_nil
          @response.from.should == @target
          @response.received_at.should == @received_at.to_f
        end

        context "when fails" do
          context "with connectivity error" do
            it "queues push if queueing and does not respond" do
              @options = {:time_to_live => @ttl}
              @packet = @sender.build_packet(:send_request, @type, @payload, @target, @options, &@callback)
              @sender = create_sender(:http, :offline_queueing => true)
              @sender.initialize_offline_queue
              @sender.enable_offline_mode
              @client.should_receive(:request).and_raise(RightScale::Exceptions::ConnectivityFailure, "disconnected").once
              flexmock(@sender.offline_handler).should_receive(:queue_request).
                  with(:send_push, @type, @payload, @target, @token, (@now + @ttl).to_i, 0).once
              flexmock(@sender).should_receive(:handle_response).never
              @sender.send(:http_send_once, :send_push, @target, @packet, @received_at).should be_true
            end

            it "queues request if queueing and does not respond" do
              @options = {:time_to_live => @ttl}
              @packet = @sender.build_packet(:send_request, @type, @payload, @target, @options, &@callback)
              @sender = create_sender(:http, :offline_queueing => true)
              @sender.initialize_offline_queue
              @sender.enable_offline_mode
              @client.should_receive(:request).and_raise(RightScale::Exceptions::ConnectivityFailure, "disconnected").once
              flexmock(@sender.offline_handler).should_receive(:queue_request).
                  with(:send_request, @type, @payload, @target, @token, (@now + @ttl).to_i, 0, @callback).once
              flexmock(@sender).should_receive(:handle_response).never
              @sender.send(:http_send_once, :send_request, @target, @packet, @received_at, &@callback).should be_true
            end

            it "responds with retry result if not queueing" do
              @client.should_receive(:request).and_raise(RightScale::Exceptions::ConnectivityFailure, "Server not responding").once
              @sender.send(:http_send_once, :send_request, @target, @packet, @received_at, &@callback).should be_true
              @response.results.retry?.should be_true
              @response.results.content.should == "Server not responding"
            end
          end

          it "responds with retry result if retryable error" do
            @client.should_receive(:request).and_raise(RightScale::Exceptions::RetryableError, "try again").once
            @sender.send(:http_send_once, :send_request, @target, @packet, @received_at, &@callback).should be_true
            @response.results.retry?.should be_true
            @response.results.content.should == "try again"
          end

          it "responds with error result if internal error" do
            @client.should_receive(:request).and_raise(RightScale::Exceptions::InternalServerError.new("unprocessable", "Router")).once
            @sender.send(:http_send_once, :send_request, @target, @packet, @received_at, &@callback).should be_true
            @response.results.error?.should be_true
            @response.results.content.should == "Router internal error"
          end

          it "does not respond to request if terminating" do
            @client.should_receive(:request).and_raise(RightScale::Exceptions::Terminating, "going down").once
            flexmock(@sender).should_receive(:handle_response).never
            @sender.send(:http_send_once, :send_request, @target, @packet, @received_at, &@callback).should be_true
          end

          it "responds with error result if HTTP error" do
            @client.should_receive(:request).and_raise(RightScale::HttpExceptions.create(400, "bad data")).once
            @sender.send(:http_send_once, :send_request, @target, @packet, @received_at, &@callback).should be_true
            @response.results.error?.should be_true
            @response.results.content.should == "400 Bad Request: bad data"
          end

          it "responds with error result if unexpected error" do
            @log.should_receive(:error).with(/Failed to send/, StandardError, :trace).once
            @client.should_receive(:request).and_raise(StandardError, "unexpected").once
            @sender.send(:http_send_once, :send_request, @target, @packet, @received_at, &@callback).should be_true
            @response.results.error?.should be_true
            @response.results.content.should == "Agent agent internal error"
          end
        end
      end
    end

    context :amqp do
      before(:each) do
        @sender = create_sender(:amqp)
        @token = "random_token"
        flexmock(RightSupport::Data::UUID).should_receive(:generate).and_return(@token).by_default
        @packet = @sender.build_packet(:send_push, @type, @payload, @target, @options)
      end

      context :amqp_send do
        it "stores pending request for use in responding if callback specified" do
          @packet = @sender.build_packet(:send_push, @type, @payload, @target, @options, &@callback)
          flexmock(@sender).should_receive(:amqp_send_once)
          @sender.send(:amqp_send, :send_push, @target, @packet, @received_at, &@callback).should be_true
          @sender.pending_requests[@token].should_not be_nil
        end

        it "does not store pending request if callback not specified" do
          flexmock(@sender).should_receive(:amqp_send_once)
          @sender.send(:amqp_send, :send_push, @target, @packet, @received_at).should be_true
          @sender.pending_requests[@token].should be_nil
        end

        it "publishes without retry capability if send_push" do
          flexmock(@sender).should_receive(:amqp_send_once).with(@packet).once
          @sender.send(:amqp_send, :send_push, @target, @packet, @received_at).should be_true
        end

        it "publishes with retry capability if send_request" do
          @packet = @sender.build_packet(:send_request, @type, @payload, @target, @options, &@callback)
          flexmock(@sender).should_receive(:amqp_send_retry).with(@packet, @token).once
          @sender.send(:amqp_send, :send_request, @target, @packet, @received_at, &@callback).should be_true
        end

        context "when fails" do

          context "with offline error" do
            it "submits request to offline handler if queuing" do
              @options = {:time_to_live => @ttl}
              @packet = @sender.build_packet(:send_push, @type, @payload, @target, @options)
              @sender = create_sender(:amqp, :offline_queueing => true)
              @sender.initialize_offline_queue
              @sender.enable_offline_mode
              flexmock(@sender.offline_handler).should_receive(:queue_request).
                  with(:send_push, @type, @payload, @target, @token, (@now + @ttl).to_i, 0).once
              flexmock(@sender).should_receive(:amqp_send_once).and_raise(RightScale::Sender::TemporarilyOffline).once
              @sender.send(:amqp_send, :send_push, @target, @packet, @received_at).should be_true
              @sender.pending_requests[@token].should be_nil
            end

            it "responds with retry result if not queueing" do
              flexmock(@sender).should_receive(:amqp_send_once).and_raise(RightScale::Sender::TemporarilyOffline).once
              @sender.send(:amqp_send, :send_push, @target, @packet, @received_at, &@callback).should be_true
              @sender.offline_handler.queue.size.should == 0
              @sender.pending_requests[@token].should_not be_nil # because send_push does not get deleted when deliver
              @response.results.retry?.should be_true
              @response.results.content.should == "lost RightNet connectivity"
            end
          end

          it "responds with non-delivery result if send failure" do
            flexmock(@sender).should_receive(:amqp_send_once).and_raise(RightScale::Sender::SendFailure).once
            @sender.send(:amqp_send, :send_push, @target, @packet, @received_at, &@callback).should be_true
            @sender.pending_requests[@token].should_not be_nil # because send_push does not get deleted when deliver
            @response.results.non_delivery?.should be_true
            @response.results.content.should == "send failed unexpectedly"
          end
        end
      end

      context :amqp_send_once do
        it "publishes request to request queue" do
          @client.should_receive(:publish).with(hsh(:name => "request"), @packet, hsh(:persistent => true,
              :mandatory => true, :broker_ids => nil)).and_return(@broker_ids).once
          @sender.send(:amqp_send_once, @packet, @broker_ids).should == @broker_ids
        end

        context "when fails" do
          it "raises TemporarilyOffline if no connected brokers" do
            @log.should_receive(:error).with(/Failed to publish/, RightAMQP::HABrokerClient::NoConnectedBrokers, :no_trace).once
            @client.should_receive(:publish).and_raise(RightAMQP::HABrokerClient::NoConnectedBrokers).once
            lambda { @sender.send(:amqp_send_once, @packet) }.should raise_error(RightScale::Sender::TemporarilyOffline)
          end

          it "raises SendFailure if unexpected exception" do
            @log.should_receive(:error).with(/Failed to publish/, StandardError, :trace).once
            @client.should_receive(:publish).and_raise(StandardError, "unexpected").once
            lambda { @sender.send(:amqp_send_once, @packet) }.should raise_error(RightScale::Sender::SendFailure)
          end
        end
      end

      context :amqp_send_retry do
        before(:each) do
          flexmock(RightSupport::Data::UUID).should_receive(:generate).and_return("retry token")
          @packet = @sender.build_packet(:send_request, @type, @payload, @target, :token => @token, &@callback)
        end

        it "publishes request to request queue" do
          @client.should_receive(:publish).with(hsh(:name => "request"), @packet, hsh(:persistent => nil,
              :mandatory => true, :broker_ids => nil)).and_return(@broker_ids).once
          @sender.send(:amqp_send_retry, @packet, @token).should be_true
        end

        it "does not rescue if publish fails" do
          @log.should_receive(:error).with(/Failed to publish request/, RightAMQP::HABrokerClient::NoConnectedBrokers, :no_trace).once
          @client.should_receive(:publish).and_raise(RightAMQP::HABrokerClient::NoConnectedBrokers).once
          lambda { @sender.send(:amqp_send_retry, @packet, @token) }.should raise_error(RightScale::Sender::TemporarilyOffline)
        end

        it "does not retry if retry timeout not set" do
          @sender = create_sender(:amqp, :retry_interval => 10)
          @client.should_receive(:publish).once
          flexmock(EM).should_receive(:add_timer).never
          @sender.send(:amqp_send_retry, @packet, @token).should be_true
        end

        it "does not retry if retry interval not set" do
          @sender = create_sender(:amqp, :retry_timeout => 60)
          @client.should_receive(:publish).once
          flexmock(EM).should_receive(:add_timer).never
          @sender.send(:amqp_send_retry, @packet, @token).should be_true
        end

        context "when retry enabled" do
          it "uses timer to wait for a response" do
            @sender = create_sender(:amqp, :retry_timeout => 0.3, :retry_interval => 0.1)
            @client.should_receive(:publish).once
            flexmock(EM).should_receive(:add_timer).once
            @sender.send(:amqp_send_retry, @packet, @token).should be_true
          end

          it "stops retrying if response was received" do
            @sender = create_sender(:amqp, :retry_timeout => 0.3, :retry_interval => 0.1)
            @client.should_receive(:publish).once
            flexmock(EM).should_receive(:add_timer).and_yield.once
            @sender.pending_requests[@token].should be_nil
            @sender.send(:amqp_send_retry, @packet, @token).should be_true
          end

          it "stops retrying if request has expired" do
            @options = {:time_to_live => @ttl}
            flexmock(Time).should_receive(:now).and_return(@now, @now + @ttl)
            @packet = @sender.build_packet(:send_request, @type, @payload, @target, @options, &@callback)
            @sender = create_sender(:amqp, :retry_timeout => 0.3, :retry_interval => 0.1)
            @client.should_receive(:publish).and_return(@broker_ids).once
            flexmock(@sender.connectivity_checker).should_receive(:check).once
            flexmock(EM).should_receive(:add_timer).and_yield.once
            @log.should_receive(:warning).with(/RE-SEND TIMEOUT/).once
            @sender.send(:amqp_send, :send_request, @target, @packet, @received_at, &@callback).should be_true
            @response.results.non_delivery?.should be_true
            @response.results.content.should == RightScale::OperationResult::RETRY_TIMEOUT
            @sender.pending_requests.empty?.should be_true
          end

          it "keeps retrying if has not exceeded retry timeout" do
            EM.run do
              @sender = create_sender(:amqp, :retry_timeout => 0.3, :retry_interval => 0.1)
              @client.should_receive(:publish).and_return(@broker_ids).twice
              flexmock(@sender.connectivity_checker).should_receive(:check).once
              @sender.send(:amqp_send, :send_request, @target, @packet, @received_at, &@callback).should be_true

              EM.add_timer(0.15) do
                @sender.pending_requests.empty?.should be_false
                result = RightScale::Result.new(@token, nil, RightScale::OperationResult.success, nil)
                @sender.handle_response(result)
              end

              EM.add_timer(0.3) do
                EM.stop
                @response.results.success?.should be_true
                @sender.pending_requests.empty?.should be_true
              end
            end
          end

          it "stops retrying and responds with non-delivery result if exceeds retry timeout" do
            EM.run do
              @sender = create_sender(:amqp, :retry_timeout => 0.1, :retry_interval => 0.1)
              @client.should_receive(:publish).and_return(@broker_ids).once
              @log.should_receive(:warning).with(/RE-SEND TIMEOUT/).once
              flexmock(@sender.connectivity_checker).should_receive(:check).once
              @sender.send(:amqp_send, :send_request, @target, @packet, @received_at, &@callback).should be_true

              EM.add_timer(0.3) do
                EM.stop
                @response.results.non_delivery?.should be_true
                @response.results.content.should == RightScale::OperationResult::RETRY_TIMEOUT
                @sender.pending_requests.empty?.should be_true
              end
            end
          end

          it "stops retrying if temporarily offline" do
            @sender = create_sender(:amqp, :retry_timeout => 0.3, :retry_interval => 0.1)
            @client.should_receive(:publish).and_return(@broker_ids).once.ordered
            @client.should_receive(:publish).and_raise(RightAMQP::HABrokerClient::NoConnectedBrokers).once.ordered
            flexmock(EM).should_receive(:add_timer).and_yield.once
            @log.should_receive(:error).with(/Failed to publish request/, RightAMQP::HABrokerClient::NoConnectedBrokers, :no_trace).once
            @log.should_receive(:error).with(/Failed retry.*temporarily offline/).once
            @sender.send(:amqp_send, :send_request, @target, @packet, @received_at, &@callback).should be_true
            @sender.pending_requests[@token].should_not be_nil
            @sender.pending_requests["retry token"].should_not be_nil
          end

          it "stops retrying if there is a send failure" do
            @sender = create_sender(:amqp, :retry_timeout => 0.3, :retry_interval => 0.1)
            @client.should_receive(:publish).and_return(@broker_ids).once.ordered
            @client.should_receive(:publish).and_raise(StandardError, "failed").once.ordered
            flexmock(EM).should_receive(:add_timer).and_yield.once
            @log.should_receive(:error).with(/Failed to publish request/, StandardError, :trace).once
            @log.should_receive(:error).with(/Failed retry.*send failure/).once
            @sender.send(:amqp_send, :send_request, @target, @packet, @received_at, &@callback).should be_true
            @sender.pending_requests[@token].should_not be_nil
            @sender.pending_requests["retry token"].should_not be_nil
          end

          it "stops retrying if there is an unexpected exception" do
            # This will actually call amqp_send_retry 3 times recursively because add_timer always yields immediately
            @sender = create_sender(:amqp, :retry_timeout => 0.3, :retry_interval => 0.1)
            @client.should_receive(:publish).and_return(@broker_ids)
            @log.should_receive(:error).with(/Failed retry.*without responding/, StandardError, :trace).twice
            flexmock(EM).should_receive(:add_timer).and_yield
            flexmock(@sender.connectivity_checker).should_receive(:check).and_raise(StandardError).once
            @sender.send(:amqp_send, :send_request, @target, @packet, @received_at, &@callback).should be_true
            @sender.pending_requests[@token].should_not be_nil
            @sender.pending_requests["retry token"].should_not be_nil
          end
        end
      end
    end

    context :deliver_response do
      it "calls the response handler" do
        pending_request = RightScale::PendingRequest.new(:send_request, @received_at, @callback)
        @sender.pending_requests[@token] = pending_request
        response = RightScale::Result.new(@token, "to", RightScale::OperationResult.success, @target)
        @sender.send(:deliver_response, response, pending_request).should be_true
        @response.should == response
      end

      it "deletes associated pending request if is it a Request" do
        pending_request = RightScale::PendingRequest.new(:send_request, @received_at, @callback)
        @sender.pending_requests[@token] = pending_request
        response = RightScale::Result.new(@token, "to", RightScale::OperationResult.success, @target)
        @sender.send(:deliver_response, response, pending_request).should be_true
        @sender.pending_requests[@token].should be_nil
      end

      it "does not delete pending request if it is a Push" do
        pending_request = RightScale::PendingRequest.new(:send_push, @received_at, @callback)
        @sender.pending_requests[@token] = pending_request
        response = RightScale::Result.new(@token, "to", RightScale::OperationResult.success, @target)
        @sender.send(:deliver_response, response, pending_request).should be_true
        @sender.pending_requests[@token].should_not be_nil
      end

      it "deletes any associated retry requests" do
        @parent_token = RightSupport::Data::UUID.generate
        pending_request = RightScale::PendingRequest.new(:send_request, @received_at, @callback)
        @sender.pending_requests[@token] = pending_request
        @sender.pending_requests[@token].retry_parent_token = @parent_token
        @sender.pending_requests[@parent_token] = @sender.pending_requests[@token].dup
        response = RightScale::Result.new(@token, "to", RightScale::OperationResult.success, @target)
        @sender.send(:deliver_response, response, pending_request).should be_true
        @sender.pending_requests[@token].should be_nil
        @sender.pending_requests[@parent_token].should be_nil
      end
    end

    context :queueing? do
      it "returns true if offline handling enabled and currently in queueing mode" do
        @sender = create_sender(:http, :offline_queueing => true)
        flexmock(@sender.offline_handler).should_receive(:queueing?).and_return(true)
        @sender.send(:queueing?).should be_true
      end

      it "returns false if offline handling disabled" do
        flexmock(@sender.offline_handler).should_receive(:queueing?).and_return(true)
        @sender.send(:queueing?).should be_false
      end

      it "returns false if offline handling enabled but not in queueing mode" do
        @sender = create_sender(:http, :offline_queueing => true)
        flexmock(@sender.offline_handler).should_receive(:queueing?).and_return(false)
        @sender.send(:queueing?).should be_false
      end
    end
  end
end
