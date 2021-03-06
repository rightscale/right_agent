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

module RightScale

  # HTTP interface to RightApi for use when mapping actor-based requests to API requests
  class ApiClient < BaseRetryClient

    # RightApi API version for use in X-API-Version header
    API_VERSION = "1.5"

    # Maximum length of an audit summary as enforced by RightApi
    MAX_AUDIT_SUMMARY_LENGTH = 255

    # Default time to wait for HTTP connection to open
    DEFAULT_OPEN_TIMEOUT = 2

    # Default time to wait for response from request, which is chosen to be 5 seconds greater
    # than the response timeout inside the RightNet router
    DEFAULT_REQUEST_TIMEOUT = 35

    # Map from actor-based request paths to RightApi HTTP verb and path; only requests whose type
    # matches an entry in this hash will be routed to the RightApi; all others will be routed to RightNet
    API_MAP = {
      "/auditor/create_entry"              => [:post, "/audit_entries"],
      "/auditor/update_entry"              => [:post, "/audit_entries/:id/append"],
      "/booter/declare"                    => [:post, "/right_net/booter/declare"],
      "/booter/get_repositories"           => [:get,  "/right_net/booter/get_repositories"],
      "/booter/get_boot_bundle"            => [:get,  "/right_net/booter/get_boot_bundle"],
      "/booter/get_decommission_bundle"    => [:get,  "/right_net/booter/get_decommission_bundle"],
      "/booter/get_missing_attributes"     => [:get,  "/right_net/booter/get_missing_attributes"],
      "/booter/get_login_policy"           => [:get,  "/right_net/booter/get_login_policy"],
      "/forwarder/schedule_right_script"   => [:post, "/right_net/scheduler/bundle_right_script"],
      "/forwarder/schedule_recipe"         => [:post, "/right_net/scheduler/bundle_recipe"],
      "/forwarder/shutdown"                => [:post, "/right_net/scheduler/shutdown"],
      "/key_server/retrieve_public_keys"   => [:get,  "/right_net/key_server/retrieve_public_keys"],
      "/router/ping"                       => [:get,  "/health-check"],
      # Currently cannot use RightApi for query_tags because it does not support server
      # tag scoping by account or deployment like the router does
      #"/router/query_tags"                 => [:post, "/tags/by_tag"],
      "/router/add_tags"                   => [:post, "/tags/multi_add"],
      "/router/delete_tags"                => [:post, "/tags/multi_delete"],
      "/state_recorder/record"             => [:put,  "/right_net/state_recorder/record"],
      "/storage_valet/get_planned_volumes" => [:get,  "/right_net/storage_valet/get_planned_volumes"],
      "/storage_valet/attach_volume"       => [:post, "/right_net/storage_valet/attach_volume"],
      "/storage_valet/detach_volume"       => [:post, "/right_net/storage_valet/detach_volume"],
      "/updater/update_inputs"             => [:post, "/right_net/scheduler/update_inputs"],
      "/vault/read_documents"              => [:get,  "/right_net/vault/read_documents"] }

    # Symbols for audit request parameters whose values are to be hidden when logging
    AUDIT_FILTER_PARAMS = ["detail", "text"]

    # Resource href for this agent
    attr_reader :self_href

    # Create RightApi client of specified type
    #
    # @param [AuthClient] auth_client providing authorization session for HTTP requests
    #
    # @option options [Numeric] :open_timeout maximum wait for connection; defaults to DEFAULT_OPEN_TIMEOUT
    # @option options [Numeric] :request_timeout maximum wait for response; defaults to DEFAULT_REQUEST_TIMEOUT
    # @option options [Numeric] :retry_timeout maximum before stop retrying; defaults to DEFAULT_RETRY_TIMEOUT
    # @option options [Array] :retry_intervals between successive retries; defaults to DEFAULT_RETRY_INTERVALS
    # @option options [Boolean] :retry_enabled for requests that fail to connect or that return a retry result
    # @option options [Numeric] :reconnect_interval for reconnect attempts after lose connectivity
    #
    # @raise [ArgumentError] auth client does not support this client type
    def initialize(auth_client, options)
      init(:api, auth_client, options.merge(:server_name => "RightApi", :api_version => API_VERSION))
    end

    # Route a request to a single target or multiple targets with no response expected
    # Persist the request en route to reduce the chance of it being lost at the expense of some
    # additional network overhead
    # Enqueue the request if the target is not currently available
    # Never automatically retry the request if there is the possibility of it being duplicated
    # Set time-to-live to be forever
    #
    # @param [String] type of request as path specifying actor and action
    # @param [Hash, NilClass] payload for request
    # @param [String, Hash, NilClass] target for request, which may be identity of specific
    #   target, hash for selecting potentially multiple targets, or nil if routing solely
    #   using type; hash may contain:
    #   [String] :agent_id serialized identity of specific target
    #   [Array] :tags that must all be associated with a target for it to be selected
    #   [Hash] :scope for restricting routing which may contain:
    #     [Integer] :account id that agents must be associated with to be included
    #     [Integer] :shard id that agents must be in to be included, or if value is
    #       Packet::GLOBAL, ones with no shard id
    #   [Symbol] :selector for picking from qualified targets: :any or :all;
    #     defaults to :any
    #
    # @option options [String] :request_uuid uniquely identifying this request; defaults to
    #   randomly generated
    # @option options [Numeric] :time_to_live seconds before request expires and is to be ignored;
    #   non-positive value or nil means never expire
    #
    # @return [NilClass] always nil since there is no expected response to the request
    #
    # @raise [Exceptions::Unauthorized] authorization failed
    # @raise [Exceptions::ConnectivityFailure] cannot connect to server, lost connection
    #   to it, or it is out of service or too busy to respond
    # @raise [Exceptions::RetryableError] request failed but if retried may succeed
    # @raise [Exceptions::Terminating] closing client and terminating service
    # @raise [Exceptions::InternalServerError] internal error in server being accessed
    def push(type, payload, target, options = {})
      map_request(type, payload, options)
    end

    # Route a request to a single target with a response expected
    # Automatically retry the request if a response is not received in a reasonable amount of time
    # or if there is a non-delivery response indicating the target is not currently available
    # Timeout the request if a response is not received in time, typically configured to 30 sec
    # Because of retries there is the possibility of duplicated requests, and these are detected and
    # discarded automatically for non-idempotent actions
    # Allow the request to expire per the agent's configured time-to-live, typically 1 minute
    #
    # @param [String] type of request as path specifying actor and action
    # @param [Hash, NilClass] payload for request
    # @param [String, Hash, NilClass] target for request, which may be identity of specific
    #   target, hash for selecting targets of which one is picked randomly, or nil if routing solely
    #   using type; hash may contain:
    #   [String] :agent_id serialized identity of specific target
    #   [Array] :tags that must all be associated with a target for it to be selected
    #   [Hash] :scope for restricting routing which may contain:
    #     [Integer] :account id that agents must be associated with to be included
    #
    # @option options [String] :request_uuid uniquely identifying this request; defaults to
    #   randomly generated
    # @option options [Numeric] :time_to_live seconds before request expires and is to be ignored;
    #   non-positive value or nil means never expire
    #
    # @return [Result, NilClass] response from request
    #
    # @raise [Exceptions::Unauthorized] authorization failed
    # @raise [Exceptions::ConnectivityFailure] cannot connect to server, lost connection
    #   to it, or it is out of service or too busy to respond
    # @raise [Exceptions::RetryableError] request failed but if retried may succeed
    # @raise [Exceptions::Terminating] closing client and terminating service
    # @raise [Exceptions::InternalServerError] internal error in server being accessed
    def request(type, payload, target, options = {})
      map_request(type, payload, options)
    end

    # Determine whether request supported by this client
    #
    # @param [String] type of request as path specifying actor and action
    #
    # @return [Array] HTTP verb and path
    def support?(type)
      API_MAP.has_key?(type)
    end

    protected

    # Convert request to RightApi form and then make request via HTTP
    #
    # @param [String] type of request as path specifying actor and action
    # @param [Hash, NilClass] payload for request
    #
    # @option options [String] :request_uuid uniquely identifying this request
    # @option options [Numeric] :time_to_live seconds before request expires and is to be ignored
    #
    # @return [Object, NilClass] response from request
    #
    # @raise [Exceptions::Unauthorized] authorization failed
    # @raise [Exceptions::ConnectivityFailure] cannot connect to server, lost connection
    #   to it, or it is too busy to respond
    # @raise [Exceptions::RetryableError] request failed but if retried may succeed
    # @raise [Exceptions::Terminating] closing client and terminating service
    # @raise [Exceptions::InternalServerError] internal error in server being accessed
    def map_request(type, payload, options)
      verb, path = API_MAP[type]
      raise ArgumentError, "Unsupported request type: #{type}" if path.nil?
      actor, action = type.split("/")[1..-1]
      path, params, request_options = parameterize(actor, action, payload, path)
      if action == "query_tags"
        map_query_tags(verb, params, action, options.merge(request_options))
      else
        map_response(make_request(verb, path, params, action, options.merge(request_options)), path)
      end
    end

    # Convert response from request into required form where necessary
    #
    # @param [Object] response received
    # @param [String] path in URI for desired resource
    #
    # @return [Object] converted response
    def map_response(response, path)
      case path
      when "/audit_entries"
        # Convert returned audit entry href to audit ID
        response.sub!(/^.*\/api\/audit_entries\//, "") if response.is_a?(String)
      when "/tags/by_resource", "/tags/by_tag"
        # Extract tags for each instance resource from response array with members of form
        # {"actions" => [], "links" => [{"rel" => "resource", "href" => <href>}, ...]}, "tags" => [{"name" => <tag>}, ...]
        tags = {}
        if response
          response.each do |hash|
            r = {}
            hash["links"].each { |l| r[l["href"]] = {"tags" => []} if l["href"] =~ /instances/ }
            hash["tags"].each { |t| r.each_key { |k| r[k]["tags"] << t["name"] } } if r.any?
            tags.merge!(r)
          end
        end
        response = tags
      end
      response
    end

    # Convert tag query request into one or more API requests and then convert responses
    # Currently only retrieving "instances" resources
    #
    # @param [Symbol] verb for HTTP REST request
    # @param [Hash] params for HTTP request
    # @param [String] action from request type
    # @param [Hash] options augmenting or overriding default options for HTTP request
    #
    # @return [Hash] tags retrieved with resource href as key and tags array as value
    def map_query_tags(verb, params, action, options)
      response = {}
      hrefs = params[:resource_hrefs] || []
      hrefs.concat(query_by_tag(verb, params[:tags], action, options)) if params[:tags]
      response = query_by_resource(verb, hrefs, action, options) if hrefs.any?
      response
    end

    # Query API for resources with specified tags
    #
    # @param [Symbol] verb for HTTP REST request
    # @param [Array] tags that all resources retrieved must have
    # @param [String] action from request type
    # @param [Hash] options augmenting or overriding default options for HTTP request
    #
    # @return [Array] resource hrefs
    def query_by_tag(verb, tags, action, options)
      path = "/tags/by_tag"
      params = {:tags => tags, :match_all => false, :resource_type => "instances"}
      map_response(make_request(verb, path, params, action, options), path).keys
    end

    # Query API for tags associated with a set of resources
    #
    # @param [Symbol] verb for HTTP REST request
    # @param [Array] hrefs for resources whose tags are to be retrieved
    # @param [String] action from request type
    # @param [Hash] options augmenting or overriding default options for HTTP request
    #
    # @return [Hash] tags retrieved with resource href as key and tags array as value
    def query_by_resource(verb, hrefs, action, options)
      path = "/tags/by_resource"
      params = {:resource_hrefs => hrefs}
      map_response(make_request(verb, path, params, action, options), path)
    end

    # Convert payload to HTTP parameters
    #
    # @param [String] actor from request type
    # @param [String] action from request type
    # @param [Hash, NilClass] payload for request
    # @param [String] path in URI for desired resource
    #
    # @return [Array] path string and parameters and options hashes
    def parameterize(actor, action, payload, path)
      options = {}
      params = {}
      if actor == "auditor"
        path = path.sub(/:id/, payload[:audit_id].to_s || "")
        params = parameterize_audit(action, payload)
        options = {:filter_params => AUDIT_FILTER_PARAMS}
      elsif actor == "router" && action =~ /_tags/
        if action != "query_tags"
          params[:resource_hrefs] = [@self_href]
        else
          params[:resource_hrefs] = Array(payload[:hrefs]).flatten.compact if payload[:hrefs]
        end
        params[:tags] = Array(payload[:tags]).flatten.compact if payload[:tags]
      else
        # Can remove :agent_identity here since now carried in the authorization as the :agent
        payload.each { |k, v| params[k.to_sym] = v if k.to_sym != :agent_identity } if payload.is_a?(Hash)
      end
      [path, params, options]
    end

    # Translate audit request payload to HTTP parameters
    # Truncate audit summary to MAX_AUDIT_SUMMARY_LENGTH, the limit imposed by RightApi
    #
    # @param [String] action requested: create_entry or update_entry
    # @param [Hash] payload from submitted request
    #
    # @return [Hash] HTTP request parameters
    #
    # @raise [ArgumentError] unknown request action
    def parameterize_audit(action, payload)
      params = {}
      summary = non_blank(payload[:summary])
      detail = non_blank(payload[:detail])
      case action
      when "create_entry"
        params[:audit_entry] = {:auditee_href => @self_href}
        params[:audit_entry][:summary] = truncate(summary, MAX_AUDIT_SUMMARY_LENGTH) if summary
        params[:audit_entry][:detail] = detail if detail
        if (user_email = non_blank(payload[:user_email]))
          params[:user_email] = user_email
        end
        params[:notify] = payload[:category] if payload[:category]
      when "update_entry"
        params[:offset] = payload[:offset] if payload[:offset]
        if summary
          params[:summary] = truncate(summary, MAX_AUDIT_SUMMARY_LENGTH)
          params[:notify] = payload[:category] if payload[:category]
        end
        params[:detail] = detail if detail
      else
        raise ArgumentError, "Unknown audit request action: #{action}"
      end
      params
    end

    # Truncate string if it exceeds maximum length
    # Do length check with bytesize rather than size since this method
    # is only intended for use with ruby 1.9 and above, otherwise
    # multi-byte characters could cause this code to be too lenient
    #
    # @param [String, NilClass] value to be truncated
    # @param [Integer] max_length allowed; must be greater than 3
    #
    # @return [String, NilClass] truncated string or original value if it is not a string
    #
    # @raise [ArgumentError] max_length too small
    def truncate(value, max_length)
      raise ArgumentError, "max_length must be greater than 3" if max_length <= 3
      if value.is_a?(String) && value.bytesize > max_length
        max_truncated = max_length - 3
        truncated = value[0, max_truncated]
        while truncated.bytesize > max_truncated do
          truncated.chop!
        end
        truncated + "..."
      else
        value
      end
    end

    # Determine whether value is non-blank
    #
    # @param [String, NilClass] value to be tested
    #
    # @return [String, NilClass] value if non-blank, otherwise nil
    def non_blank(value)
      value && !value.empty? ? value : nil
    end

    # Perform any other steps needed to make this client fully usable
    # once HTTP client has been created and server known to be accessible
    #
    # @return [TrueClass] always true
    def enable_use
      result = make_request(:get, "/sessions/instance", {}, "instance")
      @self_href = result["links"].select { |link| link["rel"] == "self" }.first["href"]
      true
    end

  end # ApiClient

end # RightScale
