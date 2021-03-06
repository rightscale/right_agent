#
# Copyright (c) 2009-2011 RightScale Inc
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

require 'restclient'

require ::File.expand_path('../../spec_helper', __FILE__)

# Mock auth client providing basic support needed by various clients
class AuthClientMock < RightScale::AuthClient
  attr_reader :test_url, :expired_called, :redirect_location

  def initialize(url, auth_header, state = nil, account_id = nil, identity = nil)
    @test_url = @api_url = @router_url = url
    @auth_header = auth_header
    @account_id = account_id
    @identity = identity || "rs-agent-1-1"
    @state = :authorized if state
  end

  def identity
    @identity
  end

  def headers
    auth_header
  end

  def auth_header
    @auth_header
  end

  def expired
    @expired_called = true
  end

  def redirect(location)
    @redirect_location = location
  end
end

# Mock WebSocket event per faye-websocket 0.7.0
class WebSocketEventMock
  attr_reader :code, :data, :reason

  def initialize(data, code = nil, reason = nil)
    @code = code
    @data = data
    @reason = reason
  end
end

# Mock WebSocket message event per faye-websocket 0.7.4
class WebSocketMessageEventMock
  attr_reader :data

  def initialize(data)
    @data = data
  end
end

# Mock WebSocket close event per faye-websocket 0.7.4
class WebSocketCloseEventMock
  attr_reader :code, :reason

  def initialize(code = nil, reason = nil)
    @code = code
    @reason = reason
  end
end

# Mock WebSocket error event per faye-websocket 0.7.4
class WebSocketErrorEventMock
  attr_reader :message

  def initialize(message = nil)
    @message = message
  end
end

# Mock of WebSocket so that can call on methods
class WebSocketClientMock
  attr_reader :sent, :closed, :code, :reason

  def initialize(version = "0.7.4")
    @version = version
  end

  def send(event)
    @sent = @sent.nil? ? event : (@sent.is_a?(Array) ? @sent << event : [@sent, event])
  end

  def close(code = nil, reason = nil)
    @code = code
    @reason = reason
    @closed = true
  end

  def onclose=(block)
    @close_block = block
  end

  def onclose(code, reason = nil)
    @event = @version == "0.7.4" ? WebSocketCloseEventMock.new(code, reason) : WebSocketEventMock.new(nil, code, reason)
    @close_block.call(@event)
  end

  def onerror=(block)
    @error_block = block
  end

  def onerror(message)
    @event = @version == "0.7.4" ? WebSocketErrorEventMock.new(message) : WebSocketEventMock.new(message)
    @error_block.call(@event)
  end

  def onmessage=(block)
    @message_block = block
  end

  def onmessage(data)
    @event = @version == "0.7.4" ? WebSocketMessageEventMock.new(data) : WebSocketEventMock.new(data)
    @message_block.call(@event)
  end
end