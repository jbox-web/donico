require "./env"
require "./error"
require "./runner"

module Donico
  # The Inspec harness the gem shipped as exe/inspec and bash/donico.lib.sh:
  # start a container from the image, run Inspec against it, always remove the
  # container afterwards. The gem's `errexit` + `EXIT` trap are an explicit
  # begin/ensure here, and the result is computed the way the shell computed
  # it (see `run`).
  class Inspec
    # One mode only. The argument is kept because it is part of the command
    # line the gem's harness had (`inspec <mode> <image> ...`) and of what the
    # start hook receives as its first argument.
    MODES = ["donico"]

    # Raises for a mode the harness does not know. Public so the CLI can
    # reject it before reading donico.yml.
    def self.check_mode!(mode : String) : Nil
      raise UsageError.new("unknown inspec mode: #{mode} (supported: #{MODES.join(", ")})") unless MODES.includes?(mode)
    end

    def initialize(@env : Env, @runner : Runner, @inspec_image : String)
      # 0, or the number of the last INT/TERM received. Written by the signal
      # handler, possibly on another thread (-Dpreview_mt).
      @signal = Atomic(Int32).new(0)
      # What the start printed, kept for the cleanup even when the start failed.
      @container_id = ""
      # 1 while the cleanup runs: a signal is then recorded but not forwarded,
      # or it would kill the very process that removes the container. This
      # covers a signal sent to donico alone (a cancelled CI job). It does not
      # cover a second Ctrl-C in a terminal, which the terminal delivers to
      # the whole foreground group, the cleanup command included: the child
      # shares donico's process group. The README says so.
      @cleaning = Atomic(Int32).new(0)
      # 0 while the built-in `docker run -d` runs: it returns at once and its
      # output is the id the cleanup needs, so a signal is recorded but not
      # forwarded to it. The project's start hook, which may do anything and
      # take long, still gets the signal.
      @forwarding = Atomic(Int32).new(1)
      @interrupted = false
    end

    # Returns the exit code of the harness: the cleanup's when it is not 0,
    # otherwise the start's when it failed, otherwise Inspec's; and 128 plus
    # the signal number whenever INT or TERM was received, after the cleanup.
    # A mode the harness does not know is rejected before anything runs (the
    # gem started a container first and failed afterwards).
    def run(mode : String, image : String, inputs : Array(String)) : Int32
      self.class.check_mode!(mode)

      @signal.set(0)
      @interrupted = false
      @env.stdout.puts "Running Inspec on #{image} (test_mode: '#{mode}', pwd: '#{@env.dir}', test_inputs: '#{inputs.join(' ')}')"
      vars = input_vars(inputs)

      start_code = run_code = cleanup_code = 0
      trap_signals
      begin
        # A signal that landed right after the traps were installed: nothing
        # was started, so there is nothing to clean up either.
        if @signal.get == 0
          start_code, run_code, cleanup_code = start_run_cleanup(mode, image, inputs, vars)
        end
      ensure
        reset_signals
      end

      received = @signal.get
      @interrupted = received != 0
      return 128 + received if received != 0
      return cleanup_code if cleanup_code != 0
      return start_code if start_code != 0
      run_code
    end

    # The three steps in order; the cleanup also runs when the start or the
    # run raises (the gem's EXIT trap). If the cleanup raises too, the first
    # error is the one that propagates: it is the cause, the second one is a
    # consequence.
    private def start_run_cleanup(mode : String, image : String, inputs : Array(String), vars : Runner::Vars) : {Int32, Int32, Int32}
      @container_id = ""
      run_code = 0
      begin
        start_code, text = start(mode, image, inputs, vars)
        # Kept even when the start failed: the gem assigned the variable
        # before `errexit` fired, and the cleanup then received it.
        @container_id = text.strip
        run_code = run_inspec(@container_id, inputs, vars) if start_code == 0 && @signal.get == 0
      rescue error
        begin
          cleanup(@container_id, vars)
        rescue
          # Dropped on purpose: the original error wins.
        end
        raise error
      end
      {start_code, run_code, cleanup(@container_id, vars)}
    end

    # True when a signal was recorded during the last `run`.
    def interrupted? : Bool
      @interrupted
    end

    # What the INT/TERM handlers do, callable without a real signal: record
    # it, then pass it on to the running child so it ends even when the
    # signal reached donico alone (a cancelled CI job).
    def handle_signal(signal : Signal) : Nil
      @signal.set(signal.value)
      @runner.forward(signal) if @cleaning.get == 0 && @forwarding.get == 1
    end

    # The gem's `load_env`: split on the first `=` only, an input without `=`
    # is its own value, an empty name is skipped.
    private def input_vars(inputs : Array(String)) : Runner::Vars
      vars = Runner::Vars.new
      inputs.each do |input|
        key, separator, value = input.partition('=')
        next if key.empty?
        vars[key] = separator.empty? ? input : value
      end
      vars
    end

    private def start(mode : String, image : String, inputs : Array(String), vars : Runner::Vars) : {Int32, String}
      hook = File.join(@env.dir, "bin", "inspec-container-up")
      if File.file?(hook)
        @runner.output(hook, [mode, image, inputs.join(' ')], vars)
      else
        @forwarding.set(0)
        begin
          @runner.output("docker", ["run", "--rm", "-d", image, "/bin/bash", "-c", "while true; do sleep 1; done"], vars)
        ensure
          @forwarding.set(1)
        end
      end
    end

    # `inspec` is given as the entrypoint, not as the first word of the command:
    # the public images (cincproject/auditor, chef/inspec) declare an entrypoint
    # of their own, which would get `inspec exec ...` as its arguments. An image
    # without one, with `inspec` on its PATH, runs the same way.
    private def run_inspec(id : String, inputs : Array(String), vars : Runner::Vars) : Int32
      args = [
        "run", "--rm",
        "--mount", "type=bind,source=#{@env.dir},target=/app",
        "--mount", "type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock",
        "--entrypoint", "inspec",
        @inspec_image,
        "exec", "/app/test/", "-t", "docker://#{id}",
        "--chef-license", "accept-silent", "--no-create-lockfile", "--show-progress",
      ]
      args.concat(inspecrc_words)
      # Each input is one argument: the gem re-split a value with whitespace.
      unless inputs.empty?
        args << "--input"
        args.concat(inputs)
      end
      @runner.system("docker", args, vars)
    end

    # Every line of the project's .inspecrc, split on whitespace: the gem
    # appended the lines to a string that the shell then word-split.
    private def inspecrc_words : Array(String)
      path = File.join(@env.dir, ".inspecrc")
      return [] of String unless File.file?(path)
      File.read(path).split
    rescue File::Error
      raise EnvironmentError.new(".inspecrc: cannot be read")
    end

    private def cleanup(id : String, vars : Runner::Vars) : Int32
      @cleaning.set(1)
      remove_container(id, vars)
    ensure
      @cleaning.set(0)
    end

    private def remove_container(id : String, vars : Runner::Vars) : Int32
      hook = File.join(@env.dir, "bin", "inspec-container-down")
      if File.file?(hook)
        @runner.system(hook, [id], vars)
      elsif !id.empty?
        @env.stdout.puts "Cleanup docker containers"
        @runner.system("docker", ["kill", id], vars)
      else
        0
      end
    end

    # `Process.on_terminate`, which ameba prefers, cannot be undone and hides
    # which signal arrived: the harness needs both, to put the default
    # disposition back and to answer 128 + the signal number.
    protected def trap_signals : Nil
      # ameba:disable Lint/SignalTrap
      Signal::INT.trap { |signal| handle_signal(signal) }
      # ameba:disable Lint/SignalTrap
      Signal::TERM.trap { |signal| handle_signal(signal) }
    end

    private def reset_signals : Nil
      Signal::INT.reset
      Signal::TERM.reset
    end
  end
end
