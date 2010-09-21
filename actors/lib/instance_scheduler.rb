#
# Copyright (c) 2009 RightScale Inc
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

class InstanceScheduler

  include RightScale::Actor

  expose :schedule_bundle, :execute, :schedule_decommission
  
  # (RightScale::ExecutableSequenceProxy) Executable sequence proxy accessed 
  # via command protocol from Cook process
  attr_reader :sequence 

  SHUTDOWN_DELAY = 180 # Number of seconds to wait for decommission scripts to finish before forcing shutdown

  # Setup signal traps for running decommission scripts
  # Start worker thread for processing executable bundles
  #
  # === Parameters
  # agent(RightScale::Agent):: Host agent
  def initialize(agent)
    @agent_identity = agent.identity
    @bundles_queue  = RightScale::BundlesQueue.new { post_decommission }
    # Wait until instance setup actor has initialized the instance state
    # We need to wait until after the InstanceSetup actor has run its
    # bundle in the Chef thread before we can use it
    EM.next_tick do
      if RightScale::InstanceState.value != 'booting'
        @bundles_queue.activate
      else
        RightScale::InstanceState.observe { |s| @bundles_queue.activate if s != 'booting' }
      end
    end
  end

  # Transition to 'decommissioned' state which will cause
  # core agent to terminate instance
  # Delete agent queue and call post-decommission callback
  def post_decommission
    RightScale::InstanceState.value = 'decommissioned'
    # Tell the registrar to delete our queue
    EM.next_tick do
      RightScale::RequestForwarder.instance.push('/registrar/remove', { :agent_identity => @agent_identity })
    end
    # If we got here through rnac --decommission then there is a callback setup and we should
    # call it. rnac will then tell us to terminate.
    # If we got here through a request then callback is set to shut us down
    if cb = @post_decommission_callback
      @post_decommission_callback = nil
      EM.next_tick { cb.call }
    else
      EM.next_tick { terminate }
    end
  end

  # Schedule given script bundle so it's run as soon as possible
  #
  # === Parameter
  # bundle(RightScale::ExecutableBundle):: Bundle to be scheduled
  #
  # === Return
  # res(RightScale::OperationResult):: Always returns success
  def schedule_bundle(bundle)
    unless bundle.executables.empty?
      audit = RightScale::AuditProxy.new(bundle.audit_id)
      audit.update_status("Scheduling execution of #{bundle.to_s}")
      context = RightScale::OperationContext.new(bundle, audit)
      @bundles_queue.push(context)
    end
    res = RightScale::OperationResult.success
  end

  # Ask agent to execute given recipe
  # Agent must forward request to core agent which will in turn run
  # schedule_bundle on this agent
  #
  # === Parameters
  # options[:recipe](String):: Recipe name
  # options[:json](Hash):: Serialized hash of attributes to be used when running recipe
  #
  # === Return
  # true:: Always return true
  def execute(options)
    options[:agent_identity] = RightScale::AgentIdentity.serialized_from_nanite(@agent_identity)
    RightScale::RequestForwarder.instance.request('/forwarder/schedule_recipe', options) do |r|
      res = RightScale::OperationResult.from_results(r)
      RightScale::RightLinkLog.info("Failed to execute recipe: #{res.content}") unless res.success?
    end
    true
  end

  # Schedule decommission, returns an error if instance is already decommissioning
  #
  # === Parameter
  # options[:bundle](RightScale::ExecutableBundle):: Decommission bundle
  # options[:user_id](Integer):: User id which requested decommission
  #
  # === Return
  # res(RightScale::OperationResult):: Status value, either success or error with message
  def schedule_decommission(options)
    return res = RightScale::OperationResult.error('Instance is already decommissioning') if RightScale::InstanceState.value == 'decommissioning'
    options = RightScale::SerializationHelper.symbolize_keys(options)
    bundle = options[:bundle]
    audit = RightScale::AuditProxy.new(bundle.audit_id)
    context = RightScale::OperationContext.new(bundle, audit, decommission=true)

    # This is the tricky bit: only set a post decommission callback if there wasn't one already set
    # by 'run_decommission'. This default callback will shutdown the instance for soft-termination.
    # The callback set by 'run_decommission' can do other things before calling 'terminate' manually.
    # 'terminate' will *not* shutdown the machine. This is so that when running the decommission
    # sequence as part of a non-soft termination we don't call shutdown.
    unless @post_decommission_callback
      @shutdown_timeout = EM::Timer.new(SHUTDOWN_DELAY) do
        msg = "Failed to decommission in less than #{SHUTDOWN_DELAY / 60} minutes, forcing shutdown"
        audit.append_error(msg, :category => RightScale::EventCategories::CATEGORY_ERROR)
        RightScale::InstanceState.shutdown(options[:user_id], options[:skip_db_update], options[:kind]) 
      end
      @post_decommission_callback = lambda do
        @shutdown_timeout.cancel
        RightScale::InstanceState.shutdown(options[:user_id], options[:skip_db_update], options[:kind]) 
      end
    end

    @bundles_queue.clear # Cancel any pending bundle
    unless bundle.executables.empty?
      audit.update_status("Scheduling execution of #{bundle.to_s} for decommission")
      @bundles_queue.push(context)
    end
    @bundles_queue.close

    RightScale::InstanceState.value = 'decommissioning'
    res = RightScale::OperationResult.success
  end

  # Schedule decommission and call given block back once decommission bundle has run
  # Note: Overrides existing post decommission callback if there was one
  # This is so that if the instance is being hard-terminated after soft-termination has started
  # then we won't try to tell the core agent to terminate us again once decommission is done
  #
  # === Block
  # Block to yield once decommission is done
  #
  # === Return
  # true:: Aways return true
  def run_decommission(&callback)
    @post_decommission_callback = callback
    if RightScale::InstanceState.value == 'decommissioned'
      # We are already decommissioned, just call the post decommission callback
      callback.call if callback
    elsif RightScale::InstanceState.value != 'decommissioning'
      # Trigger decommission
      RightScale::RequestForwarder.instance.request('/booter/get_decommission_bundle', :agent_identity => @agent_identity) do |r|
        res = RightScale::OperationResult.from_results(r)
        if res.success?
          schedule_decommission(:bundle => res.content)
        else
          RightScale::RightLinkLog.debug("Failed to retrieve decommission bundle: #{res.content}")
        end
      end
    end
    true
  end

  # Suicide, use TERM so nanite's handler gets triggered and agent unregisters
  # Note: Will *not* run the decommission scripts, call run_decommission first if you need to
  #
  # === Return
  # Well... does not return...
  def terminate
    RightScale::RightLinkLog.info("Instance agent #{@agent_identity} terminating")
    RightScale::CommandRunner.stop
    # Delay terminate a bit to give reply a chance to be sent
    EM.next_tick { Process.kill('TERM', Process.pid) }
  end

end
