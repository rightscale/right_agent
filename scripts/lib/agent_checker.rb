# === Synopsis:
#   RightScale Agent Checker (rchk)
#   (c) 2010 RightScale
#
#   Checks the agent to see if it is actively communicating with RightNet and if not
#   triggers it to re-enroll
#
#   Alternatively runs as a daemon and performs this communication check periodically,
#   as well as optionally monitoring monit
#
# === Usage
#    rchk
#
#    Options:
#      --time-limit, -t SEC      Override the default time limit since last communication for
#                                check to pass (also the interval for daemon to run these checks)
#      --attempts, -a N          Override the default number of communication check attempts
#                                before trigger re-enroll
#      --retry-interval, -r SEC  Override the default interval for retrying communication check
#      --start                   Run as a daemon process that checks agent communication after the
#                                configured time limit and repeatedly thereafter on that interval
#                                (does an immediate one-time check if --start is not specified)
#      --stop                    Stop the currently running daemon and then exit
#      --monit [SEC]             If running as a daemon, also monitor monit if it is configured
#                                on a SEC second polling interval
#      --verbose, -v             Display debug information
#      --version                 Display version information
#      --help                    Display help
#

require 'rubygems'
require 'eventmachine'
require 'optparse'
require 'fileutils'
require 'rdoc/usage'

BASE_DIR = File.join(File.dirname(__FILE__), '..', '..')

require File.expand_path(File.join(BASE_DIR, 'config', 'right_link_config'))
require File.normalize_path(File.join(BASE_DIR, 'command_protocol', 'lib', 'command_protocol'))
require File.normalize_path(File.join(BASE_DIR, 'payload_types', 'lib', 'payload_types'))
require File.normalize_path(File.join(BASE_DIR, 'scripts', 'lib', 'agent_utils'))
require File.normalize_path(File.join(BASE_DIR, 'scripts', 'lib', 'rdoc_patch'))

module RightScale

  class AgentChecker

    include Utils

    VERSION = [0, 1]

    # Default minimum seconds since last communication for instance to be considered connected
    DEFAULT_TIME_LIMIT = 12 * 60 * 60

    # Default maximum number of seconds between checks for recent communication if first check fails
    DEFAULT_RETRY_INTERVAL = 5 * 60

    # Default maximum number of attempts to check communication before decide to re-enroll
    DEFAULT_MAX_ATTEMPTS = 3

    # Maximum number of seconds to wait for a CommandIO response from the instance agent
    COMMAND_TIMEOUT = 2 * 60

    # Monit files
    MONIT = "/opt/rightscale/sandbox/bin/monit"
    MONIT_CONFIG = "/opt/rightscale/etc/monitrc"
    MONIT_PID_FILE = "/opt/rightscale/var/run/monit.pid"

    # default number of seconds between monit checks
    DEFAULT_MONIT_CHECK_INTERVAL = 5 * 60

    # Maximum number of repeated monit monitoring failures before disable monitoring monit
    MAX_MONITORING_FAILURES = 10

    # Time constants
    MINUTE = 60
    HOUR = 60 * MINUTE
    DAY = 24 * HOUR

    # Run daemon or run one agent communication check
    # If running as a daemon, store pid in same location as agent except suffix the
    # agent identity with '-rchk' (per monit setup in agent deployer)
    # Assuming that if running as daemon, monit is monitoring this daemon and
    # thus okay to abort in certain failure situations and let monit restart
    #
    # === Parameters
    # options(Hash):: Run options
    #   :time_limit(Integer):: Time limit for last communication and interval for daemon checks,
    #     defaults to DEFAULT_TIME_LIMIT
    #   :max_attempts(Integer):: Maximum number of communication check attempts,
    #     defaults to DEFAULT_MAX_ATTEMPTS
    #   :retry_interval(Integer):: Number of seconds to wait before retrying communication check,
    #     defaults to DEFAULT_RETRY_INTERVAL, reset to :time_limit if exceeds it
    #   :daemon(Boolean):: Whether to run as a daemon rather than do a one-time communication check
    #   :stop(Boolean):: Whether to stop the currently running daemon and then exit
    #   :monit(String|nil):: Directory containing monit configuration, which is to be monitored
    #   :verbose(Boolean):: Whether to display debug information
    #
    # === Return
    # true:: Always return true
    def run(options)
      @options = options
      @options[:retry_interval] = [@options[:retry_interval], @options[:time_limit]].min
      @options[:max_attempts] = [@options[:max_attempts], @options[:time_limit] / @options[:retry_interval]].min

      begin
        setup_traps

        # Retrieve instance agent configuration options
        @agent = agent_options('instance')
        error("No instance agent configured", nil, abort = true) if @agent.empty?

        # Attach to log used by instance agent
        RightLinkLog.program_name = 'RightLink'
        RightLinkLog.log_to_file_only(@agent[:log_to_file_only])
        RightLinkLog.init(@agent[:identity], RightLinkConfig[:platform].filesystem.log_dir)
        RightLinkLog.level = :debug if @options[:verbose]
        @logging_enabled = true

        # Catch any egregious eventmachine failures, especially failure to connect to agent with CommandIO
        # Exit even if running as daemon since no longer can trust EM and should get restarted automatically
        EM.error_handler do |e|
          if e.class == RuntimeError && e.message =~ /no connection/
            error("Failed to connect to agent for communication check", nil, abort = false)
            reenroll
          else
            error("Internal checker failure", e, abort = true)
          end
        end

        EM.run { check }

      rescue SystemExit => e
        raise e
      rescue Exception => e
        error("Failed to run", e, abort = true)
      end
      true
    end

    # Create options hash from command line arguments
    #
    # === Return
    # options(Hash):: Command line options
    def parse_args
      options = {
        :max_attempts   => DEFAULT_MAX_ATTEMPTS,
        :retry_interval => DEFAULT_RETRY_INTERVAL,
        :time_limit     => DEFAULT_TIME_LIMIT,
        :verbose        => false
      }

      opts = OptionParser.new do |opts|

        opts.on('-t', '--time-limit SEC') do |sec|
          options[:time_limit] = sec.to_i
        end

        opts.on('-a', '--attempts N') do |n|
          options[:max_attempts] = n.to_i
        end

        opts.on('-r', '--retry-interval SEC') do |sec|
          options[:retry_interval] = sec.to_i if sec.to_i != 0
        end

        opts.on('--start') do
          options[:daemon] = true
        end

        opts.on('--stop') do
          options[:stop] = true
        end

        opts.on('--monit [SEC]') do |sec|
          options[:monit] = sec ? sec.to_i : DEFAULT_MONIT_CHECK_INTERVAL
          options[:monit] = DEFAULT_MONIT_CHECK_INTERVAL if options[:monit] == 0
        end

        opts.on('-v', '--verbose') do
          options[:verbose] = true
        end

        # This option is only for test purposes
        opts.on('--state-path PATH') do |path|
          options[:state_path] = path
        end

      end

      opts.on_tail('--version') do
        puts version
        exit
      end

      opts.on_tail('--help') do
         RDoc::usage_from_file(__FILE__)
         exit
      end

      begin
        opts.parse!(ARGV)
      rescue SystemExit => e
        raise e
      rescue Exception => e
        error("#{e}\nUse --help for additional information", nil, abort = true)
      end
      options
    end

protected

    # Perform required checks
    #
    # === Return
    # true:: Always return true
    def check
      begin
        pid_file = PidFile.new("#{@agent[:identity]}-rchk", @agent)
        pid = pid_file.read_pid[:pid]
        if @options[:stop]
          if pid
            info("Stopping checker daemon")
            Process.kill('TERM', pid)
            pid_file.remove
          end
          EM.stop
          exit
        end

        if @options[:daemon]
          info("Checker daemon options:")
          log_options = @options.inject([]) { |t, (k, v)| t << "-  #{k}: #{v}" }
          log_options.each { |l| info(l, to_console = false, no_check = true) }

          error("Cannot start checker daemon because already running", nil, abort = true) if process_running?(pid)
          pid_file.write

          check_interval, check_modulo = if @options[:monit]
            [[@options[:monit], @options[:time_limit]].min, [@options[:time_limit] / @options[:monit], 1].max]
          else
            [@options[:time_limit], 1]
          end

          info("Starting checker daemon with #{elapsed(check_interval)} polling " +
               "and #{elapsed(@options[:time_limit])} communication time limit")

          iteration = 0
          EM.add_periodic_timer(check_interval) do
            check_monit if @options[:monit]
            check_communication(0) if iteration.modulo(check_modulo) == 0
            iteration += 1
          end
        else
          check_communication(0)
        end
      rescue SystemExit => e
        raise e
      rescue Exception => e
        error("Internal checker failure", e, abort = true)
      end
      true
    end

    # Check whether monit is running and restart it if not
    # Do not start monit if it has never run, as indicated by missing pid file
    # Disable monit monitoring if exceed maximum repeated failures
    #
    # === Return
    # true:: Always return true
    def check_monit
      begin
        pid = File.read(MONIT_PID_FILE).to_i if File.file?(MONIT_PID_FILE)
        debug("Checking monit with pid #{pid.inspect}")
        if pid && !process_running?(pid)
          if system("#{MONIT} -c #{MONIT_CONFIG}")
            info("Successfully restarted monit")
          end
        end
        @monitoring_failures = 0
      rescue Exception => e
        @monitoring_failures = (@monitoring_failures || 0) + 1
        error("Failed monitoring monit", e, abort = false)
        if @monitoring_failures > MAX_MONITORING_FAILURES
          info("Disabling monitoring of monit after #{@monitoring_failures} repeated failures")
          @options[:monit] = false
        end
      end
    end
 
    # Check communication, repeatedly if necessary
    #
    # === Parameters
    # attempt(Integer):: Number of attempts thus far
    #
    # === Return
    # true:: Always return true
    def check_communication(attempt)
      attempt += 1
      debug("Checking communication, attempt #{attempt}")
      begin
        if (time = time_since_last_communication) <= @options[:time_limit]
          @retry_timer.cancel if @retry_timer
          elapsed = elapsed(time)
          info("Passed communication check with activity as recently as #{elapsed} ago", to_console = !@options[:daemon])
          EM.stop unless @options[:daemon]
        elsif attempt <= @options[:max_attempts]
          try_communicating(attempt)
          @retry_timer = EM::Timer.new(@options[:retry_interval]) do
            error("Communication attempt #{attempt} timed out after #{elapsed(@options[:retry_interval])}")
            check_communication(attempt)
          end
        else
          reenroll
          EM.stop unless @options[:daemon]
        end
      rescue SystemExit => e
        raise e
      rescue Exception => e
        abort = !@options[:daemon] && (attempt > @options[:max_attempts])
        error("Failed communication check", e, abort)
        check_communication(attempt)
      end
      true
    end

    # Get elapsed time since last communication
    #
    # === Return
    # (Integer):: Elapsed time
    def time_since_last_communication
      state_file = @options[:state_path] || File.join(RightScale::RightLinkConfig[:agent_state_dir], 'state.js')
      state = JSON.load(File.read(state_file)) if File.file?(state_file)
      state.nil? ? (@options[:time_limit] + 1) : (Time.now.to_i - state["last_communication"])
    end

    # Ask instance agent to try to communicate
    #
    # === Parameters
    # attempt(Integer):: Number of attempts thus far
    #
    # === Return
    # true:: Always return true
    def try_communicating(attempt)
      begin
        listen_port = @agent[:listen_port]
        client = CommandClient.new(listen_port, @agent[:cookie])
        client.send_command({:name => "check_connectivity"}, @options[:verbose], COMMAND_TIMEOUT) do |r|
          res = OperationResult.from_results(JSON.load(r)) rescue nil
          if res && res.success?
            info("Successful agent communication on attempt #{attempt}")
            @retry_timer.cancel if @retry_timer
            check_communication(attempt)
          else
            error = (res && result.content) || "<unknown error>"
            error("Failed agent communication attempt", error, abort = false)
            # Let existing timer control next attempt
          end
        end
      rescue Exception => e
        error("Failed to access agent for communication check", e, abort = false)
      end
      true
    end

    # Trigger re-enroll, exit if fails
    #
    # === Return
    # true:: Always return true
    def reenroll
      unless @reenrolling
        @reenrolling = true
        begin
          info("Triggering re-enroll after unsuccessful communication check", to_console = true)
          cmd = "rs_reenroll"
          cmd += " -v" if @options[:verbose]
          success = system(cmd)
          error("Failed re-enroll after unsuccessful communication check") unless success
        rescue Exception => e
          error("Failed re-enroll after unsuccessful communication check", e, abort = true)
        end
        @reenrolling = false
      end
      true
    end

    # Checks whether process with given pid is running
    #
    # === Parameters
    # pid(Fixnum):: Process id to be checked
    #
    # === Return
    # (Boolean):: true if process is running, otherwise false
    def process_running?(pid)
      return false unless pid
      Process.getpgid(pid) != -1
    rescue Errno::ESRCH
      false
    end

    # Setup signal traps
    #
    # === Return
    # true:: Always return true
    def setup_traps
      ['INT', 'TERM'].each do |sig|
        old = trap(sig) do
          EM.stop rescue nil
          old.call if old.is_a? Proc
        end
      end
      true
    end

    # Log debug information
    #
    # === Parameters
    # info(String):: Information to be logged
    #
    # === Return
    # true:: Always return true
    def debug(info)
      info(info) if @options[:verbose]
    end

    # Log information
    #
    # === Parameters
    # info(String):: Information to be logged
    # to_console(Boolean):: Whether to also display to console even if :verbose is false
    # no_check(Boolean):: Whether to omit '[check]' prefix in logged info
    #
    # === Return
    # true:: Always return true
    def info(info, to_console = false, no_check = false)
      RightLinkLog.info("#{no_check ? '' : '[check] '}#{info}")
      puts(info) if @options[:verbose] || to_console
    end

    # Handle error by logging message and optionally aborting execution
    #
    # === Parameters
    # description(String):: Description of context where error occurred
    # error(Exception|String):: Exception or error message
    # abort(Boolean):: Whether to abort execution
    #
    # === Return
    # true:: If do not abort
    def error(description, error = nil, abort = false)
      if @logging_enabled
        msg = "[check] #{description}"
        msg += ", aborting" if abort
        if error
          if error.is_a?(Exception)
            msg += ": #{error}\n" + error.backtrace.join("\n")
          else
            msg += ": #{error}"
          end
        end
        RightLinkLog.error(msg)
      end

      msg = description
      msg += ": #{error}" if error
      puts "** #{msg}"

      if abort
        EM.stop rescue nil
        exit(1)
      end
      true
    end

    # Convert elapsed time in seconds to displayable format
    #
    # === Parameters
    # time(Integer|Float):: Elapsed time
    #
    # === Return
    # (String):: Display string
    def elapsed(time)
      time = time.to_i
      if time <= MINUTE
        "#{time} sec"
      elsif time <= HOUR
        minutes = time / MINUTE
        seconds = time - (minutes * MINUTE)
        "#{minutes} min #{seconds} sec"
      elsif time <= DAY
        hours = time / HOUR
        minutes = (time - (hours * HOUR)) / MINUTE
        "#{hours} hr #{minutes} min"
      else
        days = time / DAY
        hours = (time - (days * DAY)) / HOUR
        minutes = (time - (days * DAY) - (hours * HOUR)) / MINUTE
        "#{days} day#{days == 1 ? '' : 's'} #{hours} hr #{minutes} min"
      end
    end

    # Version information
    #
    # === Return
    # ver(String):: Version information
    def version
      ver = "rchk #{VERSION.join('.')} - RightScale Agent Checker (c) 2010 RightScale"
    end

  end # AgentChecker

end # RightScale

# Copyright (c) 2010 RightScale Inc
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
