require "./env"
require "./error"
require "./subprocess"

module Donico
  # Every external process donico starts goes through a Runner, so that task
  # specs substitute a recording fake and never start a real docker.
  abstract class Runner
    alias Vars = Hash(String, String)

    # Replaces the process in production; returns the exit code in specs.
    abstract def exec(command : String, args : Array(String), env : Vars = Vars.new) : Int32
    # Runs to completion with inherited streams; the exit code, 128 + n when
    # killed by signal n.
    abstract def system(command : String, args : Array(String), env : Vars = Vars.new) : Int32
    # Runs to completion; stdout and stderr captured together, in the order
    # written.
    abstract def capture(command : String, args : Array(String), env : Vars = Vars.new) : {Int32, String}
    # Runs to completion; stdout captured alone, stderr inherited.
    abstract def output(command : String, args : Array(String), env : Vars = Vars.new) : {Int32, String}
    # Sends the signal to the child currently running, if any.
    abstract def forward(signal : Signal) : Nil
    # Starts the command with its three streams on the null device and does
    # not wait for it.
    abstract def detach(command : String, args : Array(String)) : Nil

    # Base variables first, explicit ones on top.
    def self.merge_env(base : Vars, extra : Vars) : Vars
      base.merge(extra)
    end

    # The exit code of a finished child: its own, or 128 + n when it was
    # killed by signal n (`exit_code?` is nil then).
    def self.exit_code_of(status : Process::Status) : Int32
      status.exit_code? || 128 + (status.exit_signal?.try(&.value) || 0)
    end
  end

  # The runner that starts real processes. The child's environment is exactly
  # `env.vars` plus the explicit variables of the call (never the donico
  # process's own), and its working directory is `env.dir`.
  class Runner::Real < Runner
    def initialize(@env : Env)
      @running = nil.as(Process?)
      # `forward` runs from a signal-handling fiber, possibly on another
      # thread (-Dpreview_mt) than the one that set or clears `@running`.
      @lock = Mutex.new
    end

    def exec(command : String, args : Array(String), env : Vars = Vars.new) : Int32
      vars = Runner.merge_env(@env.vars, env)
      log("exec", command, args)
      path = resolve(command, vars)
      spawning(path) { Process.exec(path, args, env: vars, clear_env: true, chdir: @env.dir) }
    end

    def system(command : String, args : Array(String), env : Vars = Vars.new) : Int32
      vars = Runner.merge_env(@env.vars, env)
      log("with_exit_status", command, args)
      path = resolve(command, vars)
      process = spawning(path) do
        Process.new(path, args, env: vars, clear_env: true, chdir: @env.dir,
          input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      end
      Runner.exit_code_of(running(process, &.wait))
    end

    def capture(command : String, args : Array(String), env : Vars = Vars.new) : {Int32, String}
      vars = Runner.merge_env(@env.vars, env)
      log("run_cmd", command, args)
      path = resolve(command, vars)
      status, text = begin
        spawning(path) do
          Subprocess.run(path, args, chdir: @env.dir, env: vars, clear_env: true,
            started: ->(process : Process) { set_running(process) })
        end
      ensure
        set_running(nil)
      end
      {Runner.exit_code_of(status), text}
    end

    def output(command : String, args : Array(String), env : Vars = Vars.new) : {Int32, String}
      vars = Runner.merge_env(@env.vars, env)
      log("run_cmd", command, args)
      path = resolve(command, vars)
      process = spawning(path) do
        Process.new(path, args, env: vars, clear_env: true, chdir: @env.dir,
          input: Process::Redirect::Close, output: Process::Redirect::Pipe, error: Process::Redirect::Inherit)
      end
      text = nil.as(String?)
      status = running(process) do |child|
        text = child.output.gets_to_end
        child.wait
      end
      {Runner.exit_code_of(status), text.to_s}
    end

    # What opens a URL. `system` would let the opener write over the text
    # interface, `capture` would wait on a pipe the browser keeps open. The
    # child is not forwarded signals (it is not the running child) and is
    # reaped by a fiber of its own, so that it never lingers as a zombie.
    def detach(command : String, args : Array(String)) : Nil
      vars = @env.vars
      log("detach", command, args)
      path = resolve(command, vars)
      File.open(File::NULL, "r+") do |null|
        process = spawning(path) do
          Process.new(path, args, env: vars, clear_env: true, chdir: @env.dir, input: null, output: null, error: null)
        end
        spawn { process.wait }
      end
    end

    def forward(signal : Signal) : Nil
      @lock.synchronize { @running.try(&.signal(signal)) }
    rescue RuntimeError
      # The child may have been reaped, or be about to be, between the moment
      # it exits and the moment `running` forgets it: signalling it then
      # raises ESRCH, and a signal handler must never raise.
    end

    # Keeps `process` as the running child for the length of the block, so
    # `forward` can reach it, and always forgets it afterwards. The Process
    # only exists once the spawn has returned, so a signal forwarded between
    # the spawn and this registration is lost: that window, a few
    # instructions wide, is the one that cannot be closed from here.
    private def running(process : Process, & : Process -> Process::Status) : Process::Status
      set_running(process)
      begin
        yield process
      ensure
        set_running(nil)
      end
    end

    protected def set_running(process : Process?) : Nil
      @lock.synchronize { @running = process }
    end

    # Looks the executable up itself, in the PATH of the child's environment:
    # the stdlib would search the PATH of the donico process, which is not the
    # one a `.env` may have changed. A path with a slash is used as given
    # (relative to env.dir). Raises EnvironmentError when nothing runnable is
    # found, rather than letting the spawn fail with a bare errno.
    private def resolve(command : String, vars : Vars) : String
      raise EnvironmentError.new("#{@env.dir} is not a directory") unless Dir.exists?(@env.dir)
      candidates = if command.includes?('/')
                     [File.expand_path(command, @env.dir)]
                   else
                     (vars["PATH"]? || "").split(':').reject(&.empty?).map { |dir| File.join(File.expand_path(dir, @env.dir), command) }
                   end
      present = candidates.select { |path| File.file?(path) }
      if found = present.find { |path| File::Info.executable?(path) }
        found
      elsif first = present.first?
        raise EnvironmentError.new("#{first} is not executable")
      else
        raise EnvironmentError.new("#{command} not found in PATH")
      end
    end

    # `resolve` only proves the file exists and has an executable bit; the
    # spawn can still fail (an interpreter that does not exist, a binary for
    # another platform). That is reported like the other environment
    # problems, not as a backtrace. A file with no shebang is a case apart:
    # musl (the released binaries) and Darwin refuse it with ENOEXEC, which
    # ends here too, while a binary linked against glibc runs it through
    # /bin/sh, as execvpe does there.
    private def spawning(path : String, & : -> T) : T forall T
      yield
    rescue error : File::Error
      reason = error.os_error.try(&.message) || error.message
      raise EnvironmentError.new("#{path} cannot be executed: #{reason}")
    end

    # The call as the gem's shell helpers logged it. Only the command line is
    # logged, never the environment, which may carry secrets.
    private def log(label : String, command : String, args : Array(String)) : Nil
      return if @env.vars.has_key?("DONICO_QUIET")
      @env.stdout.puts "#{label}: #{([command] + args).join(' ')}"
    end
  end
end
