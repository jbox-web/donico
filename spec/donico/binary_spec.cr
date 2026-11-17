require "../spec_helper"

private BINARY = File.expand_path(File.join(__DIR__, "..", "..", "bin", "donico"))
private ROOT   = File.expand_path(File.join(__DIR__, "..", ".."))

# `crystal spec` compiles the specs, not bin/donico: run on its own after a
# change to src/, it would exercise the binary of an earlier build and stay
# green whatever the change. The examples below refuse to run on a binary
# older than one of its sources.
private def stale_source : String?
  built = File.info(BINARY).modification_time
  sources = Dir.glob(File.join(ROOT, "src", "**", "*")) + [File.join(ROOT, "shard.yml")]
  sources.select { |path| File.file?(path) }.find { |path| File.info(path).modification_time > built }
end

private YAML_TRIXIE = <<-YAML
  registry: registry.example.net/images/base
  image_name: foo
  matrix:
    - version: "1.2.3"
      distro: trixie
      build_args:
        - FOO=bar
      login_env: [A]
  YAML

# Runs the compiled binary in a temporary project, with a fake `docker` first
# on a PATH made of nothing else but /usr/bin:/bin, and an environment built
# from scratch: nothing leaks in from the machine, and no real docker can run.
# The fake prints its arguments, then $FOO, then A, then BUILD_DATE.
private def run_binary(args : Array(String), extra_env : Hash(String, String) = {} of String => String,
                       dotenv : String? = nil) : {Int32, String, String}
  root = File.join(Dir.tempdir, "donico-binary-#{Process.pid}-#{Random::Secure.hex(4)}")
  fake_dir = File.join(root, "fake")
  project = File.join(root, "project")
  Dir.mkdir_p(fake_dir)
  Dir.mkdir_p(project)
  begin
    fake = File.join(fake_dir, "docker")
    File.write(fake, "#!/bin/sh\necho \"$*\"\necho \"$FOO\"\necho \"A=$A\"\necho \"BUILD_DATE=$BUILD_DATE\"\n")
    File.chmod(fake, 0o755)
    File.write(File.join(project, "donico.yml"), YAML_TRIXIE)
    File.write(File.join(project, ".env"), dotenv) if dotenv
    env = {"PATH" => "#{fake_dir}:/usr/bin:/bin"}.merge(extra_env)
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, args, env: env, clear_env: true, chdir: project, output: stdout, error: stderr)
    {status.exit_code, stdout.to_s, stderr.to_s}
  ensure
    FileUtils.rm_rf(root)
  end
end

private NEW_SESSION = File.expand_path(File.join(__DIR__, "..", "fixtures", "bin", "new-session"))

# A fake docker that logs each call's arguments. The container start prints an
# id; the Inspec call records its pid, then becomes a 30 second sleep.
private FAKE_DOCKER_SLEEPING = <<-SH
  #!/bin/sh
  echo "$*" >> "$DOCKER_LOG"
  case "$*" in
    "run --rm -d "*) echo cid42 ;;
    "run --rm --mount "*) echo $$ > "$DOCKER_PIDS"; exec sleep 30 ;;
  esac
  SH

# How a signal reaches the binary in `send_to_inspec_run`.
private enum Target
  ProcessGroup
  BinaryAlone
end

# Starts `donico inspec donico img` in a new process group, waits (at most
# five seconds) until the fake docker is sleeping in the Inspec call, sends
# the signal, then waits (at most five seconds) for the binary to end. Returns
# its exit status, the docker log and the seconds between signal and exit. No
# process survives, whatever the outcome: the sleep and the whole group are
# killed afterwards.
private def send_to_inspec_run(signal : Signal, target : Target) : {Int32?, Array(String), Float64}
  root = File.join(Dir.tempdir, "donico-signal-#{Process.pid}-#{Random::Secure.hex(4)}")
  fake_dir = File.join(root, "fake")
  project = File.join(root, "project")
  log = File.join(root, "docker.log")
  pids = File.join(root, "docker.pid")
  Dir.mkdir_p(fake_dir)
  Dir.mkdir_p(project)
  begin
    File.write(File.join(fake_dir, "docker"), FAKE_DOCKER_SLEEPING)
    File.chmod(File.join(fake_dir, "docker"), 0o755)
    File.write(File.join(project, "donico.yml"), YAML_TRIXIE)
    env = {"PATH" => "#{fake_dir}:/usr/bin:/bin", "DOCKER_LOG" => log, "DOCKER_PIDS" => pids}
    child = Process.new(NEW_SESSION, [BINARY, "inspec", "donico", "img"], env: env, clear_env: true,
      chdir: project, output: IO::Memory.new, error: IO::Memory.new)
    # The one and only waiter of the child. A second `child.wait`, from the
    # cleanup below while this fiber was still blocked in the first, never
    # returned: a binary that ignored the signal then hung the whole suite
    # instead of failing the example.
    exited = Channel(Process::Status).new(1)
    spawn { exited.send(child.wait) }
    begin
      wait_for_file(pids)
      sent_at = Time.instant
      case target
      in .process_group? then Process.signal(signal, -child.pid)
      in .binary_alone?  then Process.signal(signal, child.pid)
      end
      status = receive_within(exited, 5.seconds)
      elapsed = (Time.instant - sent_at).total_seconds
      {status.try(&.exit_code), File.exists?(log) ? File.read_lines(log) : [] of String, elapsed}
    ensure
      kill_leftovers(child, pids)
      # Reaped through the same waiter, so no zombie outlives the example. A
      # child that already ended was reaped by the wait above.
      receive_within(exited, 5.seconds) unless child.terminated?
    end
  ensure
    FileUtils.rm_rf(root)
  end
end

# Polls (five seconds at most) until the fake docker has written its pid, that
# is until it is sleeping inside the Inspec call.
private def wait_for_file(path : String) : Nil
  deadline = Time.instant + 5.seconds
  until File.exists?(path) && !File.read(path).strip.empty?
    raise "the fake docker never reached the Inspec call" if Time.instant > deadline
    sleep 20.milliseconds
  end
end

# The status the waiter fiber sends, or nil when the child is still running
# after `span`.
private def receive_within(exited : Channel(Process::Status), span : Time::Span) : Process::Status?
  select
  when status = exited.receive
    status
  when timeout(span)
    nil
  end
end

# Kills the sleep the fake docker became and the whole group of the binary,
# whatever happened: a failed example must not leave a process behind. The
# caller reaps the child.
private def kill_leftovers(child : Process, pids : String) : Nil
  text = File.exists?(pids) ? File.read(pids).strip : ""
  [text.to_i?, -child.pid].compact.each do |pid|
    Process.signal(Signal::KILL, pid)
  rescue RuntimeError
    # Already gone: nothing left to kill.
  end
end

describe "bin/donico", tags: "binary" do
  before_each do
    if source = stale_source
      raise "bin/donico is older than #{Path[source].relative_to(ROOT)}: run `mise dev:build` (or `mise dev:spec`, which builds first)"
    end
  end

  it "replaces itself with docker buildx bake, exporting BUILD_DATE and no build arg" do
    code, stdout, stderr = run_binary(["trixie:1.2.3:build"], {"FOO" => "shell"})

    stderr.should eq ""
    code.should eq 0
    # stdout is a pipe here, not a terminal: the log line is printed anyway.
    stdout.lines.should contain "exec: docker buildx bake trixie-1-2-3-build"
    stdout.lines.should contain "buildx bake trixie-1-2-3-build"
    # FOO=bar is a build arg of the row: it is in the bakefile, not in the
    # environment of docker, which keeps the FOO it inherited.
    stdout.lines.should contain "shell"
    stdout.lines.should_not contain "bar"
    stdout.lines.any?(&.matches?(/\ABUILD_DATE=\d{8}\z/)).should be_true
  end

  it "hands the variables of .env to docker" do
    code, stdout, _ = run_binary(["trixie:1.2.3:login"], dotenv: "A=1\n")

    code.should eq 0
    stdout.lines.any? { |line| line.matches?(%r{\Arun -it --rm -e A foo/1\.2\.3/trixie:\d+ /bin/bash\z}) }.should be_true
    stdout.lines.should contain "A=1"
  end

  it "traps INT sent to the process group, removes the container and exits 130" do
    status, log, _ = send_to_inspec_run(Signal::INT, Target::ProcessGroup)

    log.last?.should eq "kill cid42"
    status.should eq 130
  end

  it "removes the container and exits 143 well before the fake's sleep ends when TERM reaches the binary alone" do
    status, log, elapsed = send_to_inspec_run(Signal::TERM, Target::BinaryAlone)

    log.last?.should eq "kill cid42"
    status.should eq 143
    # The fake sleeps 30 seconds, so ending anywhere under 15 proves the
    # signal was forwarded to it. A tighter bound flaked on a loaded machine:
    # what is measured here is forwarding, not speed.
    elapsed.should be < 15.0
  end
end
