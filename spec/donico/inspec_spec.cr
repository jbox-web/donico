require "../spec_helper"

private YAML_ANY = "registry: r\nimage_name: foo\nmatrix:\n  - version: \"1\"\n    distro: d\n"

private INSPEC_IMAGE = "tools.example/inspec:latest"

# An Inspec whose traps are installed and a signal lands at once, before the
# start: the window between installing the handlers and the first call.
private class EarlySignalInspec < Donico::Inspec
  protected def trap_signals : Nil
    super
    handle_signal(Signal::TERM)
  end
end

private def harness(env : Donico::Env, runner : Donico::Runner) : Donico::Inspec
  Donico::Inspec.new(env, runner, INSPEC_IMAGE)
end

private def write_in(env : Donico::Env, path : String, content : String) : Nil
  full = File.join(env.dir, path)
  Dir.mkdir_p(File.dirname(full))
  File.write(full, content)
end

describe Donico::Inspec do
  it "starts a container, runs Inspec on it, then kills it, with the inputs as environment" do
    with_project(YAML_ANY) do |env|
      runner = RecordingRunner.new.script(0, "abc123\n")
      inputs = ["run_mode=dind", "k=a=b", "flag", "=skipped"]

      code = harness(env, runner).run("donico", "img:1", inputs)

      code.should eq 0
      variables = {"run_mode" => "dind", "k" => "a=b", "flag" => "flag"}
      runner.calls.map { |call| {call.kind, call.command, call.args, call.env} }.should eq [
        {:output, "docker", ["run", "--rm", "-d", "img:1", "/bin/bash", "-c", "while true; do sleep 1; done"], variables},
        {:system, "docker", [
          "run", "--rm", "--mount", "type=bind,source=#{env.dir},target=/app",
          "--mount", "type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock",
          INSPEC_IMAGE, "inspec", "exec", "/app/test/", "-t", "docker://abc123",
          "--chef-license", "accept-silent", "--no-create-lockfile", "--show-progress",
          "--input", "run_mode=dind", "k=a=b", "flag", "=skipped",
        ], variables},
        {:system, "docker", ["kill", "abc123"], variables},
      ]
      env.stdout.to_s.should eq(
        "Running Inspec on img:1 (test_mode: 'donico', pwd: '#{env.dir}', test_inputs: 'run_mode=dind k=a=b flag =skipped')\n" \
        "Cleanup docker containers\n")
    end
  end

  it "omits --input without inputs and keeps a value with whitespace as one argument" do
    with_project(YAML_ANY) do |env|
      runner = RecordingRunner.new.script(0, "id1")
      harness(env, runner).run("donico", "img", [] of String)
      runner.calls[1].args.should_not contain "--input"
      runner.calls[1].args.last.should eq "--show-progress"

      runner = RecordingRunner.new.script(0, "id1")
      harness(env, runner).run("donico", "img", ["msg=hello big world"])
      runner.calls[1].args.last(2).should eq ["--input", "msg=hello big world"]
    end
  end

  it "takes the container id from standard output, trimmed" do
    with_project(YAML_ANY) do |env|
      runner = RecordingRunner.new.script(0, "  abc123 \n")
      harness(env, runner).run("donico", "img", [] of String)
      runner.calls[1].args.should contain "docker://abc123"
      runner.calls[2].args.should eq ["kill", "abc123"]
    end
  end

  describe "exit code" do
    it "is the code of Inspec when everything else succeeds" do
      with_project(YAML_ANY) do |env|
        runner = RecordingRunner.new.script(0, "id").script(100)
        harness(env, runner).run("donico", "img", [] of String).should eq 100
      end
    end

    it "is the code of the start when it failed, with no Inspec call and a cleanup on the id it printed" do
      with_project(YAML_ANY) do |env|
        runner = RecordingRunner.new.script(125, "idfail\n")
        harness(env, runner).run("donico", "img", [] of String).should eq 125
        runner.calls.size.should eq 2
        runner.calls[1].args.should eq ["kill", "idfail"]
        env.stdout.to_s.should contain "Cleanup docker containers"
      end
    end

    it "is the code of the cleanup when it is not 0" do
      with_project(YAML_ANY) do |env|
        runner = RecordingRunner.new.script(0, "id").script(100).script(7)
        harness(env, runner).run("donico", "img", [] of String).should eq 7
      end
    end

    # The three codes that can be non-zero at once: the cleanup's wins over
    # the start's (README, "Exit status of test").
    it "is the code of the cleanup when the start and the cleanup both failed" do
      with_project(YAML_ANY) do |env|
        runner = RecordingRunner.new.script(125, "idfail").script(7)
        harness(env, runner).run("donico", "img", [] of String).should eq 7
        runner.calls.map(&.kind).should eq [:output, :system]
      end
    end

    it "is the code of the start when it failed without printing an id, and no cleanup runs" do
      with_project(YAML_ANY) do |env|
        runner = RecordingRunner.new.script(3, "")
        harness(env, runner).run("donico", "img", [] of String).should eq 3
        runner.calls.size.should eq 1
        env.stdout.to_s.should_not contain "Cleanup"
      end
    end
  end

  describe "project hooks" do
    it "starts through bin/inspec-container-up by absolute path" do
      with_project(YAML_ANY) do |env|
        write_in(env, "bin/inspec-container-up", "#!/bin/sh\necho x\n")
        runner = RecordingRunner.new.script(0, "hookid")

        harness(env, runner).run("donico", "img", ["a=1", "b=2"])

        first = runner.calls.first
        first.kind.should eq :output
        first.command.should eq "#{env.dir}/bin/inspec-container-up"
        first.args.should eq ["donico", "img", "a=1 b=2"]
        first.env.should eq({"a" => "1", "b" => "2"})
        runner.calls[1].args.should contain "docker://hookid"
      end
    end

    it "cleans up through bin/inspec-container-down, even with an empty id, and prints nothing" do
      with_project(YAML_ANY) do |env|
        write_in(env, "bin/inspec-container-down", "#!/bin/sh\n")
        runner = RecordingRunner.new.script(9, "")

        code = harness(env, runner).run("donico", "img", ["a=1"])

        code.should eq 9
        last = runner.calls.last
        last.kind.should eq :system
        last.command.should eq "#{env.dir}/bin/inspec-container-down"
        last.args.should eq [""]
        last.env.should eq({"a" => "1"})
        env.stdout.to_s.should_not contain "Cleanup docker containers"
      end
    end
  end

  describe "project hooks through the real runner" do
    # The fake above records a hook without starting it. These two go through
    # Runner::Real, with a fake docker first on a PATH of its own.
    it "runs an executable start hook and uses the id it prints" do
      hook = "#!/bin/sh\necho \"hook $*\" >> \"$LOG\"\necho hookid\n"
      docker = "#!/bin/sh\necho \"docker $*\" >> \"$LOG\"\n"
      with_project(YAML_ANY, files: {"bin/inspec-container-up" => hook, "fake/docker" => docker}) do |env|
        File.chmod(File.join(env.dir, "bin", "inspec-container-up"), 0o755)
        File.chmod(File.join(env.dir, "fake", "docker"), 0o755)
        log = File.join(env.dir, "calls.log")
        vars = {"PATH" => "#{env.dir}/fake:/usr/bin:/bin", "LOG" => log, "DONICO_QUIET" => "1"}
        real = Donico::Env.new(vars, env.dir, IO::Memory.new, IO::Memory.new, env.now)

        Donico::Inspec.new(real, Donico::Runner::Real.new(real), INSPEC_IMAGE).run("donico", "img", ["a=1"]).should eq 0

        lines = File.read_lines(log)
        lines.size.should eq 3
        lines[0].should eq "hook donico img a=1"
        lines[1].should contain " -t docker://hookid "
        lines[2].should eq "docker kill hookid"
      end
    end

    it "refuses a start hook without the executable bit, and still cleans up" do
      down = "#!/bin/sh\necho \"down [$1]\" >> \"$LOG\"\n"
      with_project(YAML_ANY, files: {"bin/inspec-container-up" => "#!/bin/sh\n", "bin/inspec-container-down" => down}) do |env|
        File.chmod(File.join(env.dir, "bin", "inspec-container-up"), 0o644)
        File.chmod(File.join(env.dir, "bin", "inspec-container-down"), 0o755)
        log = File.join(env.dir, "calls.log")
        vars = {"PATH" => "/usr/bin:/bin", "LOG" => log, "DONICO_QUIET" => "1"}
        real = Donico::Env.new(vars, env.dir, IO::Memory.new, IO::Memory.new, env.now)

        error = expect_raises(Donico::EnvironmentError) do
          Donico::Inspec.new(real, Donico::Runner::Real.new(real), INSPEC_IMAGE).run("donico", "img", [] of String)
        end

        error.message.should eq "#{env.dir}/bin/inspec-container-up is not executable"
        File.read_lines(log).should eq ["down []"]
      end
    end
  end

  describe ".inspecrc" do
    it "reports a file that cannot be read, after removing the container" do
      with_project(YAML_ANY) do |env|
        write_in(env, ".inspecrc", "--color\n")
        path = File.join(env.dir, ".inspecrc")
        File.chmod(path, 0o000)
        begin
          # Root reads anything: the case cannot be produced there.
          pending!("file stays readable (running as root)") if File::Info.readable?(path)
          runner = RecordingRunner.new.script(0, "id")
          expect_raises(Donico::EnvironmentError, ".inspecrc: cannot be read") do
            harness(env, runner).run("donico", "img", [] of String)
          end
          runner.calls.last.args.should eq ["kill", "id"]
        ensure
          File.chmod(path, 0o644)
        end
      end
    end

    it "adds every whitespace-separated word of every line, in order, before the inputs" do
      with_project(YAML_ANY) do |env|
        write_in(env, ".inspecrc", "--reporter cli json:/app/r.json\n  --color  \n--last")
        runner = RecordingRunner.new.script(0, "id")

        harness(env, runner).run("donico", "img", ["a=1"])

        runner.calls[1].args.last(8).should eq [
          "--show-progress", "--reporter", "cli", "json:/app/r.json", "--color", "--last", "--input", "a=1",
        ]
      end
    end
  end

  it "lets the error of a start that raises propagate, with nothing to clean up" do
    with_project(YAML_ANY) do |env|
      runner = FailingRunner.new
      runner.fail_start = true
      expect_raises(Donico::EnvironmentError, "start failed") do
        harness(env, runner).run("donico", "img", [] of String)
      end
      # No id was read, and the project has no cleanup hook.
      runner.calls.map(&.kind).should eq [:output]
    end
  end

  it "runs the cleanup when the Inspec call raises, and lets the error propagate" do
    with_project(YAML_ANY) do |env|
      runner = FailingRunner.new.script(0, "id")
      runner.fail_inspec = true
      expect_raises(Donico::EnvironmentError, "inspec failed") do
        harness(env, runner).run("donico", "img", [] of String)
      end
      runner.calls.last.args.should eq ["kill", "id"]
    end
  end

  it "starts nothing when a signal is recorded right after the traps are installed" do
    with_project(YAML_ANY) do |env|
      runner = RecordingRunner.new
      code = EarlySignalInspec.new(env, runner, INSPEC_IMAGE).run("donico", "img", [] of String)

      code.should eq 143
      runner.calls.map(&.kind).should eq [:forward]
    end
  end

  describe "an exception during the cleanup" do
    it "does not replace the one already propagating from the Inspec call" do
      with_project(YAML_ANY) do |env|
        runner = FailingRunner.new.script(0, "id")
        runner.fail_inspec = true
        runner.fail_cleanup = true

        error = expect_raises(Donico::EnvironmentError) { harness(env, runner).run("donico", "img", [] of String) }
        error.message.should eq "inspec failed"
        runner.calls.last.args.should eq ["kill", "id"]
      end
    end

    it "propagates when nothing else is propagating" do
      with_project(YAML_ANY) do |env|
        runner = FailingRunner.new.script(0, "id")
        runner.fail_cleanup = true

        error = expect_raises(Donico::EnvironmentError) { harness(env, runner).run("donico", "img", [] of String) }
        error.message.should eq "cleanup failed"
      end
    end
  end

  it "rejects a mode other than donico before any call" do
    with_project(YAML_ANY) do |env|
      runner = RecordingRunner.new
      error = expect_raises(Donico::UsageError) { harness(env, runner).run("kaniko", "img", [] of String) }
      error.message.should eq "unknown inspec mode: kaniko (supported: donico)"
      runner.calls.should be_empty
      env.stdout.to_s.should eq ""
    end
  end

  describe "signals" do
    it "forwards a received signal to the running child and remembers it" do
      with_project(YAML_ANY) do |env|
        runner = RecordingRunner.new
        harness(env, runner).handle_signal(Signal::TERM)
        runner.calls.map { |call| {call.kind, call.command} }.should eq [{:forward, "TERM"}]
      end
    end

    [{Signal::INT, 130}, {Signal::TERM, 143}].each do |(signal, expected)|
      it "exits #{expected} after the cleanup when #{signal} arrives during the run, whatever Inspec returned" do
        with_project(YAML_ANY) do |env|
          runner = SignallingRunner.new.script(0, "id").script(0)
          inspec = harness(env, runner)
          runner.harness = inspec
          runner.signal = signal

          inspec.run("donico", "img", [] of String).should eq expected
          # Forwarded to the child that was running (Inspec), then the cleanup.
          runner.calls.map(&.kind).should eq [:output, :system, :forward, :system]
          runner.calls[2].command.should eq signal.to_s
          runner.calls.last.args.should eq ["kill", "id"]
        end
      end
    end

    it "exits 128 + n even when the cleanup failed" do
      with_project(YAML_ANY) do |env|
        runner = SignallingRunner.new.script(0, "id").script(0).script(7)
        inspec = harness(env, runner)
        runner.harness = inspec

        inspec.run("donico", "img", [] of String).should eq 130
      end
    end

    it "forwards again on the run that follows a signal received during a cleanup" do
      with_project(YAML_ANY) do |env|
        runner = SignallingRunner.new.script(0, "id").script(0).script(0)
        inspec = harness(env, runner)
        runner.harness = inspec
        runner.signal_on_cleanup = true
        inspec.run("donico", "img", [] of String)

        runner.signal_on_cleanup = false
        runner.script(0, "id2")
        inspec.run("donico", "img", [] of String)

        runner.calls.map(&.kind).last(4).should eq [:output, :system, :forward, :system]
      end
    end

    it "reports the run as interrupted once a signal was recorded, and resets it on the next run" do
      with_project(YAML_ANY) do |env|
        runner = SignallingRunner.new.script(0, "id").script(0)
        inspec = harness(env, runner)
        runner.harness = inspec
        inspec.interrupted?.should be_false

        inspec.run("donico", "img", [] of String)
        inspec.interrupted?.should be_true

        runner.harness = nil
        inspec.run("donico", "img", [] of String)
        inspec.interrupted?.should be_false
      end
    end

    it "records a signal received during the cleanup without forwarding it to the cleanup process" do
      with_project(YAML_ANY) do |env|
        runner = SignallingRunner.new.script(0, "id").script(0).script(0)
        inspec = harness(env, runner)
        runner.harness = inspec
        runner.signal_on_cleanup = true

        code = inspec.run("donico", "img", [] of String)

        code.should eq 130
        runner.calls.map(&.kind).should eq [:output, :system, :system]
        runner.calls.last.args.should eq ["kill", "id"]
      end
    end

    it "does not start Inspec when a signal arrived during the start, and still cleans up" do
      with_project(YAML_ANY) do |env|
        runner = SignallingRunner.new.script(0, "id")
        inspec = harness(env, runner)
        runner.harness = inspec
        runner.signal_on_output = true

        inspec.run("donico", "img", [] of String).should eq 130
        # The built-in start returns at once and prints the id the cleanup
        # needs: the signal is recorded, never forwarded to it.
        runner.calls.map(&.kind).should eq [:output, :system]
        runner.calls.last.args.should eq ["kill", "id"]
      end
    end

    it "forwards a signal that arrives during the project start hook, then skips Inspec and cleans up" do
      with_project(YAML_ANY, files: {"bin/inspec-container-up" => "#!/bin/sh\n"}) do |env|
        runner = SignallingRunner.new.script(0, "id")
        inspec = harness(env, runner)
        runner.harness = inspec
        runner.signal_on_output = true

        inspec.run("donico", "img", [] of String).should eq 130
        runner.calls.map(&.kind).should eq [:output, :forward, :system]
        runner.calls.first.command.should eq File.join(env.dir, "bin", "inspec-container-up")
        runner.calls.last.args.should eq ["kill", "id"]
      end
    end
  end
end
