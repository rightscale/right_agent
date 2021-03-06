#
# Copyright (c) 2009-2014 RightScale Inc
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

module RightScale

  # This is a retryable request for use when the execution of the request by the
  # receiver is known to be idempotent and when there is a need to indefinitely
  # pursue getting a usable response, e.g., when an instance is launching.
  # It is implemented as an EM::Deferrable and as such invokes the Proc defined
  # with its #callback method with the result content from a OperationResult::SUCCESS
  # response, or it will invoke the Proc defined with its #errback method with error
  # content if the response is an OperationResult::ERROR or CANCEL, or if the request
  # has timed out. The request can be canceled with the #cancel method, or the receiver
  # of the request may respond with a CANCEL result to cause the request to be canceled.
  # This is useful in situations where the request is never expected to succeed
  # regardless of the number of retries. By default if the response to the request
  # is an OperationResult::RETRY or NON_DELIVERY indication, the request is automatically
  # retried, as is also the case for an ERROR indication if the :retry_on_error option
  # is specified. The retry algorithm is controlled by the :retry_delay, :retry_delay_count,
  # and :max_retry_delay settings. The initial retry interval is the default or specified
  # :retry_delay and this interval is used :retry_delay_count times, at which point the
  # :retry_delay is doubled and the :retry_delay_count is halved. This backoff is again
  # applied after the new :retry_delay_count is reached, and so on until :retry_delay
  # reaches :max_retry_delay which then is used as the interval until the default or
  # specified :timeout is reached. The default :timeout is 4 days.
  class RetryableRequest

    include OperationResultHelper
    include EM::Deferrable

    # Default delay before initial retry in case of failure with -1 meaning no delay
    DEFAULT_RETRY_DELAY = 5

    # Default minimum number of retries before beginning backoff
    DEFAULT_RETRY_DELAY_COUNT = 60

    # Maximum default delay before retry when backing off
    DEFAULT_MAX_RETRY_DELAY = 60

    # Factor used for exponential backoff of retry delay
    RETRY_BACKOFF_FACTOR = 2

    # Default timeout with -1 meaning never timeout
    DEFAULT_TIMEOUT = 4 * 24 * 60 * 60

    attr_reader :raw_response

    # Send idempotent request
    # Retry until timeout is reached (indefinitely if timeout <= 0)
    # Calls deferrable callback on completion, error callback on timeout
    #
    # === Parameters
    # operation(String):: Request operation (e.g., '/booter/get_boot_bundle')
    # payload(Hash):: Request payload
    # options(Hash):: Request options
    #   :targets(Array):: Target agent identities from which to randomly choose one
    #   :retry_on_error(Boolean):: Whether request should be retried if recipient returned an error
    #   :retry_delay(Numeric):: Number of seconds delay before initial retry with -1 meaning no delay,
    #     defaults to DEFAULT_RETRY_DELAY
    #   :retry_delay_count(Numeric):: Minimum number of retries at initial :retry_delay value before
    #     increasing delay exponentially and decreasing this count exponentially, defaults to
    #     DEFAULT_RETRY_DELAY_COUNT
    #   :max_retry_delay(Numeric):: Maximum number of seconds of retry delay, defaults to DEFAULT_MAX_RETRY_DELAY
    #   :timeout(Numeric):: Number of seconds with no response before error callback gets called, with
    #     -1 meaning never, defaults to DEFAULT_TIMEOUT
    #
    # === Raises
    # ArgumentError:: If operation or payload not specified
    def initialize(operation, payload, options = {})
      raise ArgumentError.new("operation is required") unless (@operation = operation)
      raise ArgumentError.new("payload is required") unless (@payload = payload)
      @retry_on_error = options[:retry_on_error]
      @timeout = options[:timeout] || DEFAULT_TIMEOUT
      @expires_at = Time.now.to_i + @timeout if @timeout > 0
      @retry_delay = options[:retry_delay] || DEFAULT_RETRY_DELAY
      @retry_delay_count = options[:retry_delay_count] || DEFAULT_RETRY_DELAY_COUNT
      @max_retry_delay = options[:max_retry_delay] || DEFAULT_MAX_RETRY_DELAY
      @retries = 0
      @targets = options[:targets]
      @raw_response = nil
      @done = false
    end

    # Send request and retry until timeout is reached or response is received
    # Ignore duplicate responses
    # 
    # === Return
    # true:: Always return true
    def run
      cancel = Proc.new do
        msg = "Request #{@operation} timed out after #{@timeout} seconds"
        Log.info(msg)
        cancel(msg)
      end

      options = {}
      if @expires_at.nil? || (options[:time_to_live] = @expires_at - Time.now.to_i) > 0
        Sender.instance.send_request(@operation, @payload, retrieve_target(@targets), options) { |r| handle_response(r) }
        @cancel_timer = EM::Timer.new(@timeout) { cancel.call } if @cancel_timer.nil? && @timeout > 0
      else
        cancel.call
      end
      true
    end
    
    # Cancel request and call error callback
    #
    # === Parameters
    # msg(String):: Reason why request is cancelled, given to error callback
    # 
    # === Return
    # true:: Always return true
    def cancel(msg)
      if @cancel_timer
        @cancel_timer.cancel
        @cancel_timer = nil
      end
      @done = true
      fail(msg)
      true
    end

    protected

    # Process request response and retry if needed
    #
    # === Parameters
    # r(Result):: Request result
    #
    # === Return
    # true:: Always return true
    def handle_response(r)
      return true if @done
      @raw_response = r
      res = result_from(r)
      if res.success?
        if @cancel_timer
          @cancel_timer.cancel
          @cancel_timer = nil
        end
        @done = true
        succeed(res.content)
      else
        reason = res.content
        if res.non_delivery?
          Log.info("Request non-delivery (#{reason}) for #{@operation}")
        elsif res.retry?
          reason = (reason && !reason.empty?) ? reason : "RightScale not ready"
          Log.info("Request #{@operation} failed (#{reason}) and should be retried")
        elsif res.cancel?
          reason = (reason && !reason.empty?) ? reason : "RightScale cannot execute request"
          Log.info("Request #{@operation} canceled (#{reason})")
        else
          Log.info("Request #{@operation} failed (#{reason})")
        end
        if (res.non_delivery? || res.retry? || @retry_on_error) && !res.cancel?
          Log.info("Retrying in #{@retry_delay} seconds...")
          if @retry_delay > 0
            this_delay = @retry_delay
            if (@retries += 1) >= @retry_delay_count
              @retry_delay = [@retry_delay * RETRY_BACKOFF_FACTOR, @max_retry_delay].min
              @retry_delay_count = [@retry_delay_count / RETRY_BACKOFF_FACTOR, 1].max
              @retries = 0
            end
            EM.add_timer(this_delay) { run }
          else
            EM.next_tick { run }
          end
        else
          cancel(res.content)
        end
      end
      true
    end
    
    def retrieve_target(targets)
      {:agent_id => targets[rand(0xffff) % targets.size]} if targets && targets.any?
    end

  end # RetryableRequest

end # RightScale
