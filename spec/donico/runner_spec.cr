require "../spec_helper"

FIXTURE_BIN = File.expand_path("../fixtures/bin", __DIR__)

# The PATH of every runner below: enough for `sh`, `sleep` and `printf`, and
# the same on every machine, where the PATH of the process is not.
SYSTEM_PATH = "/usr/bin:/bin"

# A Runner::Real over a controlled environment.
private def real_runner(dir : String, out_io : IO = IO::Memory.new, extra : Hash(String, String) = {} of String => String) : Donico::Runner::Real
  vars = {"PATH" => SYSTEM_PATH}.merge(extra)
  Donico::Runner::Real.new(Donico::Env.new(vars, dir, out_io, IO::Memory.new, Time.utc(2026, 1, 1)))
end

# What the child sees, written by the child itself to `seen.txt` of the
# working directory it was given: `system` inherits the streams, so a file is
# the one way to read it back that works for the four ways to run a command.
PROBE = %q(printf '%s|%s|%s' "${A:-unset}" "${DONICO_SPEC_LEAK:-unset}" "$(pwd -P)" > seen.txt)

# Runs PROBE through `method` and returns what the child wrote.
private def probe(runner : Donico::Runner::Real, method : Symbol, dir : String, env : Hash(String, String) = {} of String => String) : String
  case method
  when :system  then runner.system("sh", ["-c", PROBE], env)
  when :capture then runner.capture("sh", ["-c", PROBE], env)
  else               runner.output("sh", ["-c", PROBE], env)
  end
  File.read(File.join(dir, "seen.txt"))
end

# A project directory holding an executable the kernel cannot start: its
# interpreter does not exist, so the spawn answers ENOENT on every platform.
# A file with no shebang at all would not do: glibc's execvpe re-runs it
# through /bin/sh instead of failing with ENOEXEC (musl and Darwin do fail),
# and the `exec` example below would then replace the spec process itself.
private def with_bad_executable(& : String, String ->) : Nil
  with_tmp_dir do |dir|
    path = File.join(dir, "bad-program")
    File.write(path, "#!/nonexistent/donico-spec-interpreter\nnot a program\n")
    File.chmod(path, 0o755)
    yield dir, path
  end
end

# Exposes the registration of the running child, to reproduce the window in
# which a reaped Process is still registered, and to wait for a child to be
# registered instead of sleeping a fixed time.
class RegisteringRunner < Donico::Runner::Real
  def register(process : Process?) : Nil
    set_running(process)
  end

  def running? : Bool
    @lock.synchronize { !@running.nil? }
  end
end

# Forwards TERM as soon as `runner` has a child, five seconds at most.
private def forward_term_when_running(runner : RegisteringRunner) : Nil
  spawn do
    deadline = Time.instant + 5.seconds
    until runner.running? || Time.instant > deadline
      sleep 10.milliseconds
    end
    runner.forward(Signal::TERM)
  end
end

private def registering_runner(dir : String) : RegisteringRunner
  RegisteringRunner.new(Donico::Env.new({"PATH" => SYSTEM_PATH}, dir, IO::Memory.new, IO::Memory.new, Time.utc(2026, 1, 1)))
end

describe Donico::Runner do
  describe ".merge_env" do
    it "puts the explicit variables on top of the base ones" do
      Donico::Runner.merge_env({"A" => "1", "B" => "2"}, {"B" => "3"}).should eq({"A" => "1", "B" => "3"})
    end
  end
end

describe Donico::Runner::Real do
  it "captures stdout and stderr together" do
    with_tmp_dir do |dir|
      code, text = real_runner(dir).capture("#{FIXTURE_BIN}/out_err.sh", [] of String)

      code.should eq(0)
      text.should contain("out")
      text.should contain("err")
    end
  end

  it "outputs stdout alone" do
    with_tmp_dir do |dir|
      real_runner(dir).output("#{FIXTURE_BIN}/out_err.sh", [] of String).should eq({0, "out\n"})
    end
  end

  it "returns the exit code of the child" do
    with_tmp_dir do |dir|
      real_runner(dir).system("#{FIXTURE_BIN}/exit3.sh", [] of String).should eq(3)
    end
  end

  it "returns 128 + n for a child killed by signal n" do
    with_tmp_dir do |dir|
      real_runner(dir).system("#{FIXTURE_BIN}/self_term.sh", [] of String).should eq(143)
    end
  end

  it "refuses a file without the executable bit" do
    with_tmp_dir do |dir|
      path = "#{FIXTURE_BIN}/not_executable.sh"
      error = expect_raises(Donico::EnvironmentError) do
        real_runner(dir).system(path, [] of String)
      end
      error.message.should eq("#{path} is not executable")
    end
  end

  describe "a file that is executable but cannot be run" do
    it "is reported as an EnvironmentError by system" do
      with_bad_executable do |dir, path|
        error = expect_raises(Donico::EnvironmentError) { real_runner(dir).system(path, [] of String) }
        error.message.should eq("#{path} cannot be executed: No such file or directory")
      end
    end

    it "is reported as an EnvironmentError by capture" do
      with_bad_executable do |dir, path|
        error = expect_raises(Donico::EnvironmentError) { real_runner(dir).capture(path, [] of String) }
        error.message.should eq("#{path} cannot be executed: No such file or directory")
      end
    end

    it "is reported as an EnvironmentError by output" do
      with_bad_executable do |dir, path|
        error = expect_raises(Donico::EnvironmentError) { real_runner(dir).output(path, [] of String) }
        error.message.should eq("#{path} cannot be executed: No such file or directory")
      end
    end

    it "is reported as an EnvironmentError by exec, which then still returns control" do
      with_bad_executable do |dir, path|
        error = expect_raises(Donico::EnvironmentError) { real_runner(dir).exec(path, [] of String) }
        error.message.should eq("#{path} cannot be executed: No such file or directory")
      end
    end
  end

  it "keeps the order in which the child wrote stdout and stderr" do
    with_tmp_dir do |dir|
      script = "echo 1; echo 2 >&2; echo 3"
      real_runner(dir).capture("/bin/sh", ["-c", script]).should eq({0, "1\n2\n3\n"})
    end
  end

  # The same four guarantees for the three ways to run a command to its end:
  # `clean` and `lint-dockerfile` go through `capture`, the Inspec run through
  # `system`, the container start through `output`. (`exec` replaces the
  # process: spec/donico/binary_spec.cr covers it with the compiled binary.)
  {:system, :capture, :output}.each do |method|
    describe "the child of #{method}" do
      it "gets the variables of env.vars, which is how .env reaches docker" do
        with_tmp_dir do |dir|
          runner = real_runner(dir, extra: {"A" => "from-dotenv"})
          probe(runner, method, dir).split('|')[0].should eq "from-dotenv"
        end
      end

      it "gets the explicit variables of the call on top of env.vars" do
        with_tmp_dir do |dir|
          runner = real_runner(dir, extra: {"A" => "from-dotenv"})
          probe(runner, method, dir, {"A" => "explicit"}).split('|')[0].should eq "explicit"
        end
      end

      it "does not get the variables of the donico process" do
        with_tmp_dir do |dir|
          # Not in env.vars, so it must not reach the child even when set here.
          ENV["DONICO_SPEC_LEAK"] = "leaked"
          begin
            probe(real_runner(dir), method, dir).split('|')[1].should eq "unset"
          ensure
            ENV.delete("DONICO_SPEC_LEAK")
          end
        end
      end

      it "runs in env.dir" do
        with_tmp_dir do |dir|
          probe(real_runner(dir), method, dir).split('|')[2].should eq File.realpath(dir)
        end
      end
    end
  end

  it "reports a working directory that does not exist" do
    with_tmp_dir do |dir|
      gone = File.join(dir, "gone")
      env = Donico::Env.new({"PATH" => SYSTEM_PATH}, gone, IO::Memory.new, IO::Memory.new, Time.utc(2026, 1, 1))
      error = expect_raises(Donico::EnvironmentError) do
        Donico::Runner::Real.new(env).system("#{FIXTURE_BIN}/exit3.sh", [] of String)
      end
      error.message.should eq("#{gone} is not a directory")
    end
  end

  it "reports a command absent from PATH without a backtrace" do
    with_tmp_dir do |dir|
      empty = File.join(dir, "empty")
      Dir.mkdir_p(empty)
      env = Donico::Env.new({"PATH" => empty}, dir, IO::Memory.new, IO::Memory.new, Time.utc(2026, 1, 1))
      error = expect_raises(Donico::EnvironmentError) do
        Donico::Runner::Real.new(env).capture("docker", ["info"])
      end
      error.message.should eq("docker not found in PATH")
    end
  end

  it "finds a bare command in the PATH of env.vars, not in the one of the process" do
    with_tmp_dir do |dir|
      bin = File.join(dir, "bin")
      Dir.mkdir_p(bin)
      File.copy("#{FIXTURE_BIN}/exit3.sh", File.join(bin, "fake-docker"))
      File.chmod(File.join(bin, "fake-docker"), 0o755)
      env = Donico::Env.new({"PATH" => bin}, dir, IO::Memory.new, IO::Memory.new, Time.utc(2026, 1, 1))
      Donico::Runner::Real.new(env).system("fake-docker", [] of String).should eq(3)
    end
  end

  describe "the lookup of a bare command" do
    it "resolves a relative PATH entry against env.dir" do
      with_tmp_dir do |dir|
        Dir.mkdir_p(File.join(dir, "tools"))
        File.copy("#{FIXTURE_BIN}/exit3.sh", File.join(dir, "tools", "fake-docker"))
        File.chmod(File.join(dir, "tools", "fake-docker"), 0o755)
        env = Donico::Env.new({"PATH" => "tools"}, dir, IO::Memory.new, IO::Memory.new, Time.utc(2026, 1, 1))
        Donico::Runner::Real.new(env).system("fake-docker", [] of String).should eq(3)
      end
    end

    it "skips a file without the executable bit for an executable one further down the PATH" do
      with_tmp_dir do |dir|
        first, second = File.join(dir, "first"), File.join(dir, "second")
        Dir.mkdir_p(first)
        Dir.mkdir_p(second)
        File.write(File.join(first, "fake-docker"), "#!/bin/sh\nexit 9\n")
        File.chmod(File.join(first, "fake-docker"), 0o644)
        File.copy("#{FIXTURE_BIN}/exit3.sh", File.join(second, "fake-docker"))
        File.chmod(File.join(second, "fake-docker"), 0o755)
        env = Donico::Env.new({"PATH" => "#{first}:#{second}"}, dir, IO::Memory.new, IO::Memory.new, Time.utc(2026, 1, 1))
        Donico::Runner::Real.new(env).system("fake-docker", [] of String).should eq(3)
      end
    end

    it "names the file when the only match has no executable bit" do
      with_tmp_dir do |dir|
        bin = File.join(dir, "bin")
        Dir.mkdir_p(bin)
        File.write(File.join(bin, "fake-docker"), "#!/bin/sh\n")
        File.chmod(File.join(bin, "fake-docker"), 0o644)
        env = Donico::Env.new({"PATH" => bin}, dir, IO::Memory.new, IO::Memory.new, Time.utc(2026, 1, 1))
        error = expect_raises(Donico::EnvironmentError) { Donico::Runner::Real.new(env).system("fake-docker", [] of String) }
        error.message.should eq "#{File.join(bin, "fake-docker")} is not executable"
      end
    end

    it "ignores the empty entries of PATH and reports a PATH that is not set" do
      with_tmp_dir do |dir|
        # An empty entry would mean the working directory, where this file is.
        File.copy("#{FIXTURE_BIN}/exit3.sh", File.join(dir, "fake-docker"))
        File.chmod(File.join(dir, "fake-docker"), 0o755)
        [{"PATH" => "::"}, {} of String => String].each do |vars|
          env = Donico::Env.new(vars, dir, IO::Memory.new, IO::Memory.new, Time.utc(2026, 1, 1))
          error = expect_raises(Donico::EnvironmentError) { Donico::Runner::Real.new(env).system("fake-docker", [] of String) }
          error.message.should eq "fake-docker not found in PATH"
        end
      end
    end

    it "takes a command with a slash as a path relative to env.dir" do
      with_tmp_dir do |dir|
        Dir.mkdir_p(File.join(dir, "bin"))
        File.copy("#{FIXTURE_BIN}/exit3.sh", File.join(dir, "bin", "hook"))
        File.chmod(File.join(dir, "bin", "hook"), 0o755)
        real_runner(dir).system("bin/hook", [] of String).should eq(3)
      end
    end
  end

  describe "logging" do
    it "logs the call on env.stdout before running it" do
      with_tmp_dir do |dir|
        log = IO::Memory.new
        runner = real_runner(dir, log)
        expect_raises(Donico::EnvironmentError) { runner.capture("docker", ["rmi", "x"], {"PATH" => dir}) }

        log.to_s.should eq("run_cmd: docker rmi x\n")
      end
    end

    it "labels system as with_exit_status and output as run_cmd" do
      with_tmp_dir do |dir|
        log = IO::Memory.new
        runner = real_runner(dir, log)
        runner.system("#{FIXTURE_BIN}/exit3.sh", ["a"])
        runner.output("#{FIXTURE_BIN}/exit3.sh", ["b"])

        log.to_s.should eq("with_exit_status: #{FIXTURE_BIN}/exit3.sh a\nrun_cmd: #{FIXTURE_BIN}/exit3.sh b\n")
      end
    end

    it "logs nothing when DONICO_QUIET is set" do
      with_tmp_dir do |dir|
        log = IO::Memory.new
        runner = real_runner(dir, log, {"DONICO_QUIET" => "1"})
        runner.capture("#{FIXTURE_BIN}/out_err.sh", [] of String)

        log.to_s.should be_empty
      end
    end

    it "never logs environment values" do
      with_tmp_dir do |dir|
        log = IO::Memory.new
        runner = real_runner(dir, log)
        runner.capture("#{FIXTURE_BIN}/print_a.sh", [] of String, {"A" => "s3cret-value"})

        log.to_s.should_not contain("s3cret-value")
      end
    end
  end

  describe "#forward" do
    it "signals the running child, which ends system with 128 + n" do
      with_tmp_dir do |dir|
        runner = registering_runner(dir)
        forward_term_when_running(runner)

        started = Time.instant
        runner.system("#{FIXTURE_BIN}/sleeper.sh", [] of String).should eq(143)
        (Time.instant - started).should be < 10.seconds
      end
    end

    # `clean` and `lint-dockerfile` wait in `capture`, the container start in
    # `output`: a child nobody registered could not be signalled.
    it "signals the child of capture and the child of output" do
      with_tmp_dir do |dir|
        runner = registering_runner(dir)

        forward_term_when_running(runner)
        started = Time.instant
        runner.capture("#{FIXTURE_BIN}/sleeper.sh", [] of String).first.should eq(143)

        forward_term_when_running(runner)
        runner.output("#{FIXTURE_BIN}/sleeper.sh", [] of String).first.should eq(143)
        (Time.instant - started).should be < 10.seconds
      end
    end

    it "does not raise for a child that has already exited and been reaped" do
      with_tmp_dir do |dir|
        env = Donico::Env.new({"PATH" => SYSTEM_PATH}, dir, IO::Memory.new, IO::Memory.new, Time.utc(2026, 1, 1))
        runner = RegisteringRunner.new(env)
        process = Process.new("#{FIXTURE_BIN}/exit3.sh", input: Process::Redirect::Close,
          output: Process::Redirect::Close, error: Process::Redirect::Close)
        process.wait
        runner.register(process)

        runner.forward(Signal::TERM).should be_nil
      end
    end

    it "does nothing when no child is running" do
      with_tmp_dir do |dir|
        real_runner(dir).forward(Signal::TERM).should be_nil
      end
    end
  end
end

describe RecordingRunner do
  it "records each call and answers success with an empty text by default" do
    runner = RecordingRunner.new
    runner.system("docker", ["build"], {"A" => "1"}).should eq(0)
    runner.capture("docker", ["info"]).should eq({0, ""})
    runner.output("git", ["log"]).should eq({0, ""})
    runner.exec("docker", ["run"]).should eq(0)

    runner.calls.map(&.kind).should eq([:system, :capture, :output, :exec])
    runner.calls.first.command.should eq("docker")
    runner.calls.first.args.should eq(["build"])
    runner.calls.first.env.should eq({"A" => "1"})
  end

  it "answers from the queue, in order, for every kind but forward" do
    runner = RecordingRunner.new
    runner.script(2).script(0, "text").script(5)

    runner.system("a", [] of String).should eq(2)
    runner.forward(Signal::INT)
    runner.capture("b", [] of String).should eq({0, "text"})
    runner.exec("c", [] of String).should eq(5)
    runner.system("d", [] of String).should eq(0)
  end

  it "records forward with the signal name as command" do
    runner = RecordingRunner.new
    runner.forward(Signal::TERM)

    call = runner.calls.first
    call.kind.should eq(:forward)
    call.command.should eq("TERM")
    call.args.should be_empty
    call.env.should be_empty
  end
end
