require "../../spec_helper"

private alias Versions = Donico::Fleet::Versions
private alias Reply = {Int32, JSON::Any?}

private NO_TOKEN    = "donico-manager: GITHUB_TOKEN is not set. The anonymous GitHub limit (60 requests/hour) cannot cover a full scan. Export a token and retry.\n"
private NO_TERMINAL = "donico-manager: `repos update` needs an interactive terminal.\n"

# The opener of the platform the specs run on.
private OPENER = {% if flag?(:darwin) %} "open" {% else %} "xdg-open" {% end %}

# GitHub as the scan sees it: traefik has a newer release, anything else is a
# 404 (an error row).
private def upstream : String -> Reply
  ->(path : String) : Reply do
    return {200, JSON.parse(%({"tag_name":"v3.8.0"}))} if path == "repos/traefik/traefik/releases/latest"
    {404, JSON.parse(%({"message":"Not Found"}))}
  end
end

private def throttled : String -> Reply
  ->(_path : String) : Reply { {403, JSON.parse(%({"message":"API rate limit exceeded for user ID 1."}))} }
end

# Runs `repos update` on `env`'s fleet with the given terminal predicate and
# terminal runner. `seen` records whether the terminal was reached.
private def run_update(env : Donico::Env, vars : Hash(String, String), git : FakeGit = FakeGit.new,
                       transport : String -> Reply = upstream, tty : Bool = true,
                       terminal : Versions::Screen -> Symbol = ->(_screen : Versions::Screen) { :cancelled }) : CliRun
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  github = Versions::Github.new(vars["GITHUB_TOKEN"]?, transport)
  cli = Donico::Fleet::CLI.new(stdout, stderr, env.dir, vars, env.now, git.factory, github, -> { tty }, terminal)
  code = cli.run(["repos", "update"])
  CliRun.new(code, stdout.to_s, stderr.to_s)
end

# Ticks the screen the way the terminal does, until the block holds, within a
# bound: a screen that never gets there fails the example, never hangs it.
private def drive(screen : Versions::Screen, seconds : Float64 = 10.0, &) : Nil
  deadline = Time.instant + seconds.seconds
  until yield
    raise "the screen did not get there within #{seconds}s (phase #{screen.phase})" if Time.instant > deadline
    screen.tick
    sleep 1.millisecond
  end
end

describe "donico-manager repos update" do
  describe "its preconditions" do
    # As the gem: the token is checked first. A tokenless scan of a fleet
    # yields a table that is quietly half wrong.
    it "refuses to start without GITHUB_TOKEN, before asking for a terminal" do
      with_fixture_fleet do |env|
        reached = false
        run = run_update(env, {} of String => String, tty: false,
          terminal: ->(_screen : Versions::Screen) { reached = true; :cancelled })

        run.code.should eq 1
        run.stderr.should eq NO_TOKEN
        run.stdout.should be_empty
        reached.should be_false
      end
    end

    it "takes an empty GITHUB_TOKEN for no token" do
      with_fixture_fleet do |env|
        run = run_update(env, {"GITHUB_TOKEN" => ""})
        run.stderr.should eq NO_TOKEN
      end
    end

    it "refuses to start without a terminal" do
      with_fixture_fleet do |env|
        reached = false
        run = run_update(env, {"GITHUB_TOKEN" => "spec-token"}, tty: false,
          terminal: ->(_screen : Versions::Screen) { reached = true; :cancelled })

        run.code.should eq 1
        run.stderr.should eq NO_TERMINAL
        run.stdout.should be_empty
        reached.should be_false
      end
    end

    it "finds GITHUB_TOKEN in the .env of the configuration repository" do
      with_fixture_fleet do |env|
        File.write(File.join(env.dir, ".env"), "GITHUB_TOKEN=spec-token-from-file\n")
        reached = false
        run = run_update(env, {} of String => String,
          terminal: ->(_screen : Versions::Screen) { reached = true; :cancelled })

        run.code.should eq 0
        run.stderr.should be_empty
        reached.should be_true
      end
    end

    it "takes no argument" do
      with_fixture_fleet do |env|
        run = run_fleet_in(env.dir, ["repos", "update", "traefik"], {"GITHUB_TOKEN" => "spec-token"})
        run.code.should eq 1
        run.stderr.should eq "donico-manager: unexpected argument: traefik\n"
      end
    end
  end

  # Throttling is a precondition like a missing token, not a defect: one
  # sentence, no backtrace, and no table.
  it "reports a rate limit reached during the scan as its message" do
    with_fixture_fleet do |env|
      terminal = ->(screen : Versions::Screen) do
        drive(screen) { false }
        :cancelled
      end
      run = run_update(env, {"GITHUB_TOKEN" => "spec-token"}, transport: throttled, terminal: terminal)

      run.code.should eq 1
      run.stderr.should eq "donico-manager: GitHub rate limit reached with a token: API rate limit exceeded for user ID 1.\n"
      run.stdout.should be_empty
    end
  end

  it "scans the workspace into the screen, updates first" do
    with_fixture_fleet do |env|
      images = [] of String
      terminal = ->(screen : Versions::Screen) do
        drive(screen) { screen.phase != :loading }
        images = screen.rows.map(&.image)
        screen.key(Versions::Screen::Key::Quit)
        screen.outcome
      end
      run = run_update(env, {"GITHUB_TOKEN" => "spec-token"}, terminal: terminal)

      run.code.should eq 0
      images.first.should eq "traefik"
      images.sort.should eq ["alloy", "debuerreotype", "traefik"]
    end
  end

  # The text interface holds the terminal in raw mode: a line the README
  # generators narrated there would walk across the frame being drawn.
  it "applies a bump with README generators that write nothing on stdout" do
    with_fixture_fleet do |env|
      # The fixture's traefik is written for the README generators, which read
      # it as plain YAML; donico, which regenerates its files, also wants an
      # image name.
      config = File.join(env.dir, "docker-images", "traefik", "donico.yml")
      File.write(config, "image_name: traefik\n" + File.read(config))
      git = FakeGit.new
      terminal = ->(screen : Versions::Screen) do
        drive(screen) { screen.phase == :select }
        screen.key(Versions::Screen::Key::Apply)
        drive(screen) { screen.phase == :select }
        screen.key(Versions::Screen::Key::Quit)
        screen.outcome
      end
      run = run_update(env, {"GITHUB_TOKEN" => "spec-token"}, git, terminal: terminal)

      run.code.should eq 0
      run.stdout.should be_empty
      run.stderr.should be_empty
      File.read(File.join(env.dir, "docker-images", "traefik", "donico.yml")).should contain %(- version: "3.8.0")
      # Both generators ran: the root README, removed from the copy, is back,
      # and the image README names the new version.
      File.read(File.join(env.dir, "README.md")).should contain "traefik"
      File.read(File.join(env.dir, "docker-images", "traefik", "README.md")).should contain "harbor.example.org/base/traefik:3.8.0"
      git.lines("commit").should eq [
        "git commit -m build: bump to 3.8.0 -m - donico.yml: new version\n- docker-bake.hcl: regenerated\n" \
        "- .gitlab-ci/extends/.matrix.yml: regenerated\n- README.md: regenerated tags",
        "git commit -m docs: bump traefik versions in README -m - README.md: regenerated tags for traefik -- README.md",
      ]
      git.lines("push").should be_empty
    end
  end

  it "opens the upstream repository of the row under the cursor with o, detached" do
    with_fixture_fleet do |env|
      opener = RecordingRunner.new
      git = FakeGit.new
      # The configuration repository's runner records the kind of each call.
      factory = ->(runner_env : Donico::Env) do
        runner_env.dir == env.dir ? opener.as(Donico::Runner) : git.runner_for(runner_env.dir)
      end
      terminal = ->(screen : Versions::Screen) do
        drive(screen) { screen.phase == :select }
        screen.key(Versions::Screen::Key::Open)
        screen.key(Versions::Screen::Key::Quit)
        screen.outcome
      end
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      github = Versions::Github.new("spec-token", upstream)
      code = Donico::Fleet::CLI.new(stdout, stderr, env.dir, {"GITHUB_TOKEN" => "spec-token"}, env.now, factory, github,
        -> { true }, terminal).run(["repos", "update"])

      code.should eq 0
      opener.calls.map { |call| {call.kind, call.command, call.args} }.should eq [{:detach, OPENER, ["https://github.com/traefik/traefik"]}]
    end
  end

  it "goes on when the opener cannot be started, and prints nothing" do
    with_fixture_fleet do |env|
      git = FakeGit.new
      opener = FailingOpener.new
      factory = ->(runner_env : Donico::Env) do
        runner_env.dir == env.dir ? opener.as(Donico::Runner) : git.runner_for(runner_env.dir)
      end
      phase = :none
      terminal = ->(screen : Versions::Screen) do
        drive(screen) { screen.phase == :select }
        screen.key(Versions::Screen::Key::Open)
        phase = screen.finished? ? :finished : screen.phase
        screen.key(Versions::Screen::Key::Quit)
        screen.outcome
      end
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      github = Versions::Github.new("spec-token", upstream)
      code = Donico::Fleet::CLI.new(stdout, stderr, env.dir, {"GITHUB_TOKEN" => "spec-token"}, env.now, factory, github,
        -> { true }, terminal).run(["repos", "update"])

      phase.should eq :select
      code.should eq 0
      stdout.to_s.should be_empty
      stderr.to_s.should be_empty
    end
  end
end

# A runner whose `detach` fails the way `Runner::Real` does when the opener is
# not installed.
private class FailingOpener < RecordingRunner
  def detach(command : String, args : Array(String)) : Nil
    raise Donico::EnvironmentError.new("#{command} not found in PATH")
  end
end
