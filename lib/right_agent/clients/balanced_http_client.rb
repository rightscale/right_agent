#--
# Copyright (c) 2013-2014 RightScale Inc
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

module RightScale

  # HTTP REST client for request-balanced access to RightScale servers
  # Requests can be made using the EventMachine asynchronous HTTP interface
  # in an efficient i/o non-blocking fashion using fibers or they can be made
  # using the RestClient interface; either way they are synchronous to the client
  # For the non-blocking i/o approach this class must be used from a spawned fiber
  # rather than the root fiber
  # This class is intended for use by instance agents and by infrastructure servers
  # and therefore supports both session cookie and global session-based authentication
  class BalancedHttpClient

    # When server not responding and retry is recommended
    class NotResponding < Exceptions::NestedException; end

    # HTTP status codes for which a retry is warranted, which is limited to when server
    # is not accessible for some reason (502, 503) or server response indicates that
    # the request could not be routed for some retryable reason (504)
    RETRY_STATUS_CODES = [502, 503, 504]

    # Default time for HTTP connection to open
    DEFAULT_OPEN_TIMEOUT = 2

    # Default time to wait for health check response
    HEALTH_CHECK_TIMEOUT = 5

    # Default time to wait for response from request
    DEFAULT_REQUEST_TIMEOUT = 30

    # Default health check path
    DEFAULT_HEALTH_CHECK_PATH = "/health-check"

    # Text used for filtered parameter value
    FILTERED_PARAM_VALUE = "<hidden>"

    # Environment variables to examine for proxy settings, in order
    PROXY_ENVIRONMENT_VARIABLES = ['HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY']

    # Create client for making HTTP REST requests
    #
    # @param [Array, String] urls of server being accessed as array or comma-separated string
    #
    # @option options [String] :api_version for X-API-Version header
    # @option options [String] :server_name of server for use in exceptions; defaults to host name
    # @option options [String] :health_check_path in URI for health check resource;
    #   defaults to DEFAULT_HEALTH_CHECK_PATH
    # @option options [Array] :filter_params symbols or strings for names of request parameters
    #   whose values are to be hidden when logging; can be augmented on individual requests
    # @option options [Boolean] :non_blocking i/o is to be used for HTTP requests by applying
    #   EM::HttpRequest and fibers instead of RestClient; requests remain synchronous
    def initialize(urls, options = {})
      @urls = split(urls)
      @api_version = options[:api_version]
      @server_name = options[:server_name]
      @filter_params = (options[:filter_params] || []).map { |p| p.to_s }
      @request_type = options[:non_blocking] ? :non_blocking : :blocking

      # Setup for proxy initialization if defined
      if (v = PROXY_ENVIRONMENT_VARIABLES.detect { |v| ENV.has_key?(v) })
        @proxy_uri = ENV[v].match(/^[[:alpha:]]+:\/\//) ? URI.parse(ENV[v]) : URI.parse("http://" + ENV[v])
      end

      # Initialize health check and its use in request balancer
      @health_check_proc = send("#{@request_type}_init", options)
      balancer_options = {:policy => RightSupport::Net::LB::HealthCheck, :health_check => @health_check_proc }
      @balancer = RightSupport::Net::RequestBalancer.new(@urls, balancer_options)
    end

    # Check health of server
    #
    # @param [String] host name of server
    #
    # @return [Object] health check result from server
    #
    # @raise [NotResponding] server is not responding
    def check_health(host = nil)
      begin
        @health_check_proc.call(host || @urls.first)
      rescue StandardError => e
        if e.respond_to?(:http_code) && RETRY_STATUS_CODES.include?(e.http_code)
          raise NotResponding.new("#{@server_name || host} not responding", e)
        else
          raise
        end
      end
    end

    def get(*args)
      request(:get, *args)
    end

    def post(*args)
      request(:post, *args)
    end

    def put(*args)
      request(:put, *args)
    end

    def delete(*args)
      request(:delete, *args)
    end

    # Make request
    # Encode request parameters and response using JSON
    # Apply configured authorization scheme
    # Log request/response with filtered parameters included for failure or debug mode
    #
    # @param [Symbol] verb for HTTP REST request
    # @param [String] path in URI for desired resource
    # @param [Hash] params for HTTP request
    #
    # @option options [Numeric] :open_timeout maximum wait for connection; defaults to DEFAULT_OPEN_TIMEOUT
    # @option options [Numeric] :request_timeout maximum wait for response; defaults to DEFAULT_REQUEST_TIMEOUT
    # @option options [String] :request_uuid uniquely identifying request; defaults to random generated UUID
    # @option options [Array] :filter_params symbols or strings for names of request
    #   parameters whose values are to be hidden when logging in addition to the ones
    #   provided during object initialization
    # @option options [Hash] :headers to be added to request
    # @option options [Proc] :persistent_callback called with :get to retrieve EM:HttpRequest to be used
    #   for request or called with :set and an EM:HttpRequest connection that is to returned by :get;
    #   if :get call returns nil, a new connection is created and returned with :set; this callback
    #   is only used if this HTTP client was initialized with the :non_blocking option
    # @option options [Symbol] :log_level to use when logging information about the request other than errors
    #
    # @return [Object] result returned by receiver of request
    #
    # @raise [NotResponding] server not responding, recommend retry
    def request(verb, path, params = {}, options = {})
      started_at = Time.now
      filter = @filter_params + (options[:filter_params] || []).map { |p| p.to_s }
      log_level = options[:log_level] || Log.level
      request_uuid = options[:request_uuid] || RightSupport::Data::UUID.generate
      connect_options, request_options = send("#{@request_type}_options", verb, path, params,
                                              request_headers(request_uuid, options), options)

      Log.send(log_level, "Requesting #{verb.to_s.upcase} <#{request_uuid}> " + log_text(path, params, filter, log_level))

      host_picked = nil
      result, code, body, headers = @balancer.request do |host|
        uri = URI.parse(host)
        uri.user = uri.password = nil
        host_picked = uri.to_s
        send("#{@request_type}_request", verb, path, host, connect_options, request_options, options)
      end

      log_success(result, code, body, headers, host_picked, path, request_uuid, started_at, log_level)
      result
    rescue RightSupport::Net::NoResult => e
      handle_no_result(e, host_picked) do |e2|
        log_failure(host_picked, path, params, filter, request_uuid, started_at, log_level, e2)
      end
    rescue RestClient::Exception => e
      e2 = HttpExceptions.convert(e)
      log_failure(host_picked, path, params, filter, request_uuid, started_at, log_level, e2)
      raise e2
    rescue Exception => e
      log_failure(host_picked, path, params, filter, request_uuid, started_at, log_level, e)
      raise
    end

    protected

    # Construct headers for request
    #
    # @param [String] request_uuid uniquely identifying request
    # @param [Hash] options per #request
    #
    # @return [Hash] headers for request
    def request_headers(request_uuid, options)
      headers = {"X-Request-Lineage-Uuid" => request_uuid, :accept => "application/json"}
      headers["X-API-Version"] = @api_version if @api_version
      headers.merge!(options[:headers]) if options[:headers]
      headers["X-DEBUG"] = true if Log.level == :debug
      headers
    end

    # Beautify response header keys so that in same form as RestClient
    #
    # @param [Hash] headers from response
    #
    # @return [Hash] response headers with keys as lower case symbols
    def beautify_headers(headers)
      headers.inject({}) { |out, (key, value)| out[key.gsub(/-/, '_').downcase.to_sym] = value; out }
    end

    # Initialize for "blocking" request
    #
    # @param [Hash] params for HTTP request
    # @param [String] request_headers to be applied to request
    # @param [Hash] options per #request
    #
    # @return [Proc] health check procedure
    def blocking_init(options)
      require 'restclient'

      # Initialize use of proxy if defined
      RestClient.proxy = @proxy_uri.to_s if @proxy_uri

      # Create health check proc for use by request balancer
      # Strip user and password from host name since health-check does not require authorization
      Proc.new do |host|
        uri = URI.parse(host)
        uri.user = uri.password = nil
        uri.path = uri.path + (options[:health_check_path] || DEFAULT_HEALTH_CHECK_PATH)
        request_options = {:open_timeout => DEFAULT_OPEN_TIMEOUT, :timeout => HEALTH_CHECK_TIMEOUT}
        request_options[:headers] = {"X-API-Version" => @api_version} if @api_version
        blocking_request(:get, "", uri.to_s, {}, request_options, options)
      end
    end

    # Initialize for "non-blocking" request
    #
    # @param [Hash] params for HTTP request
    # @param [String] request_headers to be applied to request
    # @param [Hash] options per #request
    #
    # @return [Proc] health check procedure
    def non_blocking_init(options)
      require 'em-http-request'

      # Initialize use of proxy if defined
      if @proxy_uri
        @proxy = {:host => @proxy_uri.host, :port => @proxy_uri.port}
        @proxy[:authorization] = [@proxy_uri.user, @proxy_uri.password] if @proxy_uri.user
      end

      # Create health check proc for use by request balancer
      # Strip user and password from host name since health-check does not require authorization
      Proc.new do |host|
        uri = URI.parse(host)
        uri.user = uri.password = nil
        uri.path = uri.path + (options[:health_check_path] || DEFAULT_HEALTH_CHECK_PATH)
        connect_options = {:connect_timeout => DEFAULT_OPEN_TIMEOUT, :inactivity_timeout => HEALTH_CHECK_TIMEOUT}
        connect_options[:proxy] = @proxy if @proxy
        request_options = {:path => uri.path}
        request_options[:head] = {"X-API-Version" => @api_version} if @api_version
        uri.path = ""
        non_blocking_request(:get, "", uri.to_s, connect_options, request_options, options)
      end
    end

    # Construct options for "blocking" request
    #
    # @param [Symbol] verb for HTTP REST request
    # @param [String] path in URI for desired resource
    # @param [Hash] params for HTTP request
    # @param [String] request_headers to be applied to request
    # @param [Hash] options per #request
    #
    # @return [Array] connect and request option hashes
    def blocking_options(verb, path, params, request_headers, options)
      request_options = {
        :open_timeout => options[:open_timeout] || DEFAULT_OPEN_TIMEOUT,
        :timeout => options[:request_timeout] || DEFAULT_REQUEST_TIMEOUT,
        :headers => request_headers }

      if [:get, :delete].include?(verb)
        # Doing own formatting because :query option for HTTPClient uses addressable gem
        # for conversion and that gem encodes arrays in a Rails-compatible fashion without []
        # markers and that is inconsistent with what sinatra expects
        request_options[:query] = "?#{format(params)}" if params.is_a?(Hash) && params.any?
      else
        request_options[:payload] = JSON.dump(params)
        request_options[:headers][:content_type] = "application/json"
      end
      [{}, request_options]
    end

    # Construct options for a "non-blocking" request
    #
    # @param [Symbol] verb for HTTP REST request
    # @param [String] path in URI for desired resource
    # @param [Hash] params for HTTP request
    # @param [String] request_headers to be applied to request
    # @param [Hash] options per #request
    #
    # @return [Array] connect and request option hashes
    def non_blocking_options(verb, path, params, request_headers, options)
      connect_options = {
        :connect_timeout => options[:open_timeout] || DEFAULT_OPEN_TIMEOUT,
        :inactivity_timeout => options[:request_timeout] || DEFAULT_REQUEST_TIMEOUT }
      connect_options[:proxy] = @proxy if @proxy

      request_body, request_path = if [:get, :delete].include?(verb)
        # Doing own formatting because :query option on EM::HttpRequest does not reliably
        # URL encode, e.g., messes up on arrays in hashes
        [nil, (params.is_a?(Hash) && params.any?) ? path + "?#{format(params)}" : path]
      else
        request_headers[:content_type] = "application/json"
        [(params.is_a?(Hash) && params.any?) ? JSON.dump(params) : nil, path]
      end
      request_options = {:path => request_path, :body => request_body, :head => request_headers}
      [connect_options, request_options]
    end

    # Make "blocking" request using RestClient (via HTTPClient) and RequestBalancer
    #
    # @param [Symbol] verb for HTTP REST request
    # @param [String] path in URI for desired resource
    # @param [String] host name of server
    # @param [Hash] connect_options for HTTP connection
    # @param [Hash] request_options for HTTP request
    # @param [Hash] options per #request
    #
    # @return [Array] result to be returned followed by response code, body, and headers
    #
    # @raise [NotResponding] server not responding, recommend retry
    def blocking_request(verb, path, host, connect_options, request_options, options)
      query = request_options.delete(:query).to_s
      if (r = RightSupport::Net::HTTPClient.new.send(verb, host + path + query, request_options.merge(connect_options)))
        [process_response(r.code, r.body, r.headers, request_options[:headers][:accept]), r.code, r.body, r.headers]
      else
        [nil, nil, nil, nil]
      end
    end

    # Make "non-blocking" request using EM::HttpRequest and RequestBalancer
    # Note that the underlying thread is not blocked by the HTTP i/o, but this call itself is blocking
    #
    # @param [Symbol] verb for HTTP REST request
    # @param [String] path in URI for desired resource
    # @param [String] host name of server
    # @param [Hash] connect_options for HTTP connection
    # @param [Hash] request_options for HTTP request
    # @param [Hash] options per #request
    #
    # @return [Array] result to be returned followed by response code, body, and headers
    #
    # @raise [NotResponding] server not responding, recommend retry
    def non_blocking_request(verb, path, host, connect_options, request_options, options)
      # Finish forming path by stripping path, if any, from host
      uri = URI.parse(host)
      request_options[:path] = uri.path + request_options[:path]
      uri.path = ""

      # Create connection unless can reuse persistent connection
      if options[:persistent_callback]
        request_options[:keepalive] = true
        unless (connection = options[:persistent_callback].call(:get, nil))
          connection = EM::HttpRequest.new(uri.to_s, connect_options)
          options[:persistent_callback].call(:set, connection)
        end
      else
        connection = EM::HttpRequest.new(uri.to_s, connect_options)
      end

      # Make request an then yield fiber until it completes
      fiber = Fiber.current
      http = connection.send(verb, request_options)
      http.errback { fiber.resume(http.error.to_s == "Errno::ETIMEDOUT" ? 504 : 500, http.error) }
      http.callback { fiber.resume(http.response_header.status, http.response, http.response_header) }
      response_code, response_body, response_headers = Fiber.yield
      response_headers = beautify_headers(response_headers) if response_headers
      result = process_response(response_code, response_body, response_headers, request_options[:head][:accept])
      [result, response_code, response_body, response_headers]
    end

    # Process HTTP response to produce result for client
    # Extract result from location header for 201 response
    # JSON-decode body of other 2xx responses except for 204
    # Raise exception if request failed
    #
    # @param [Integer] code for response status
    # @param [Object] body of response
    # @param [Hash] headers for response
    # @param [Boolean] decode JSON-encoded body on success
    #
    # @return [Object] JSON-decoded response body
    #
    # @raise [RightScale::HttpExceptions] HTTP failure with associated status code
    def process_response(code, body, headers, decode)
      if (200..207).include?(code)
        if code == 201
          result = headers[:location]
        elsif code == 204 || body.nil? || (body.respond_to?(:empty?) && body.empty?)
          result = nil
        elsif decode
          result = JSON.load(body)
          result = nil if result.respond_to?(:empty?) && result.empty?
        else
          result = body
        end
      else
        raise RightScale::HttpExceptions.create(code, body, headers)
      end
      result
    end

    # Handle no result from balancer
    # Distinguish the not responding case since it likely warrants a retry by the client
    # Also try to distinguish between the targeted server not responding and that server
    # gatewaying to another server that is not responding, so that the receiver of
    # the resulting exception is clearer as to the source of the problem
    #
    # @param [RightSupport::Net::NoResult] no_result exception raised by request balancer when it
    #   could not deliver request
    # @param [String] host server URL where request was attempted
    #
    # @yield [exception] required block called for reporting exception of interest
    # @yieldparam [Exception] exception extracted
    #
    # @return [TrueClass] always true
    #
    # @raise [NotResponding] server not responding, recommend retry
    def handle_no_result(no_result, host)
      server_name = @server_name || host
      e = no_result.details.values.flatten.last
      if no_result.details.empty?
        yield(no_result)
        raise NotResponding.new("#{server_name} not responding", no_result)
      elsif e.respond_to?(:http_code) && RETRY_STATUS_CODES.include?(e.http_code)
        yield(e)
        if e.http_code == 504 && (e.http_body && !e.http_body.empty?)
          raise NotResponding.new(e.http_body, e)
        else
          raise NotResponding.new("#{server_name} not responding", e)
        end
      else
        yield(e)
        raise e
      end
      true
    end

    # Log successful request completion
    #
    # @param [Object] result to be returned to client
    # @param [Integer, NilClass] code for response status
    # @param [Object] body of response
    # @param [Hash] headers for response
    # @param [String] host server URL where request was completed
    # @param [String] path in URI for desired resource
    # @param [String] request_uuid uniquely identifying request
    # @param [Time] started_at time for request
    # @param [Symbol] log_level to use when logging information about the request
    #   other than errors
    #
    # @return [TrueClass] always true
    def log_success(result, code, body, headers, host, path, request_uuid, started_at, log_level)
      length = (headers && headers[:content_length]) || (body && body.size) || "-"
      duration = "%.0fms" % ((Time.now - started_at) * 1000)
      completed = "Completed <#{request_uuid}> in #{duration} | #{code || "nil"} [#{host}#{path}] | #{length} bytes"
      completed << " | #{result.inspect}" if log_level == :debug
      Log.send(log_level, completed)
      true
    end

    # Log request failure
    # Also report it as audit entry if an instance is targeted
    #
    # @param [String] host server URL where request was attempted if known
    # @param [String] path in URI for desired resource
    # @param [Hash] params for request
    # @param [Array] filter list of parameters whose value is to be hidden
    # @param [String] request_uuid uniquely identifying request
    # @param [Time] started_at time for request
    # @param [Symbol] log_level to use when logging information about the request
    # @param [Exception, String] exception or message that should be logged
    #
    # @return [TrueClass] Always return true
    def log_failure(host, path, params, filter, request_uuid, started_at, log_level, exception)
      code = exception.respond_to?(:http_code) ? exception.http_code : "nil"
      duration = "%.0fms" % ((Time.now - started_at) * 1000)
      Log.error("Failed <#{request_uuid}> in #{duration} | #{code} " + log_text(path, params, filter, log_level, host, exception))
      true
    end

    # Generate log text describing request and failure if any
    #
    # @param [String] path in URI for desired resource
    # @param [Hash] params for HTTP request
    # @param [Array, NilClass] filter augmentation to base filter list
    # @param [Symbol] log_level to use when logging information about the request
    # @param [String] host server URL where request was attempted if known
    # @param [Exception, String, NilClass] exception or failure message that should be logged
    #
    # @return [String] Log text
    def log_text(path, params, filter, log_level, host = nil, exception = nil)
      filtered_params = (exception || log_level == :debug) ? filter(params, filter).inspect : nil
      text = filtered_params ? "#{path} #{filtered_params}" : path
      text = "[#{host}#{text}]" if host
      text << " | #{self.class.exception_text(exception)}" if exception
      text
    end

    # Format query parameters for inclusion in URI
    # It can only handle parameters that can be converted to a string or arrays of same,
    # not hashes or arrays/hashes that recursively contain arrays and/or hashes
    #
    # @param params [Hash] Parameters that are converted to <key>=<escaped_value> format
    #   and any value that is an array has each of its values formatted as <key>[]=<escaped_value>
    #
    # @return [String] Formatted parameter string with parameters separated by '&'
    def format(params)
      p = []
      params.each do |k, v|
        if v.is_a?(Array)
          v.each { |v2| p << "#{k.to_s}[]=#{CGI.escape(v2.to_s)}" }
        else
          p << "#{k.to_s}=#{CGI.escape(v.to_s)}"
        end
      end
      p.join("&")
    end

    # Apply parameter hiding filter
    #
    # @param [Hash, Object] params to be filtered
    # @param [Array] filter names of params as strings (not symbols) whose value is to be hidden
    #
    # @return [Hash] filtered parameters
    def filter(params, filter)
      if filter.empty? || !params.is_a?(Hash)
        params
      else
        filtered_params = {}
        params.each { |k, p| filtered_params[k] = filter.include?(k.to_s) ? FILTERED_PARAM_VALUE : p }
        filtered_params
      end
    end

    # Split string into an array unless nil or already an array
    #
    # @param [String, Array, NilClass] object to be split
    # @param [String, Regex] pattern on which to split; defaults to comma
    #
    # @return [Array] split object
    def split(object, pattern = /,\s*/)
      object ? (object.is_a?(Array) ? object : object.split(pattern)) : []
    end

    public

    # Extract text of exception for logging
    # For RestClient exceptions extract useful info from http_body attribute
    #
    # @param [Exception, String, NilClass] exception or failure message
    #
    # @return [String] exception text
    def self.exception_text(exception)
      case exception
      when String
        exception
      when RightScale::HttpException, RestClient::Exception
        if exception.http_body.nil? || exception.http_body.empty? || exception.http_body =~ /^<html>| html /
          exception.message
        else
          exception.inspect
        end
      when RightSupport::Net::NoResult, NotResponding
        "#{exception.class}: #{exception.message}"
      when Exception
        backtrace = exception.backtrace ? " in\n" + exception.backtrace.join("\n") : ""
        "#{exception.class}: #{exception.message}" + backtrace
      else
        ""
      end
    end

  end # BalancedHttpClient

end # RightScale
