require "../../spec_helper"

private SEPARATOR = "---------------------"

private def fleet_yaml : String
  <<-YAML
    registry:  harbor.example.org/base
    group:     git@example.org:factory/images
    workspace: docker-images
    images:
      - traefik
      - grafana
      - ruby

    YAML
end

private def clone(env : Donico::Env, *names : String) : Nil
  names.each { |name| Dir.mkdir_p(File.join(env.dir, "docker-images", name)) }
end

# One recording runner per directory a runner was asked for, in the order of
# the requests; `codes` makes the runner of a directory (by basename) answer
# with those statuses, one per call.
private class Recorded
  getter runners = [] of {String, RecordingRunner}
  # The environment each runner was built on, in the same order.
  getter envs = [] of Donico::Env

  # `texts` gives the text those scripted results carry (`capture`).
  def initialize(@codes : Hash(String, Array(Int32)) = {} of String => Array(Int32),
                 @texts : Hash(String, String) = {} of String => String)
  end

  def factory : Donico::Env -> Donico::Runner
    ->(env : Donico::Env) do
      runner = RecordingRunner.new
      name = File.basename(env.dir)
      @codes[name]?.try(&.each { |code| runner.script(code, @texts[name]? || "") })
      @runners << {env.dir, runner}
      @envs << env
      runner.as(Donico::Runner)
    end
  end
end

private def run_recorded(env : Donico::Env, args : Array(String), recorded : Recorded = Recorded.new) : CliRun
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = Donico::Fleet::CLI.new(stdout, stderr, env.dir, {} of String => String, env.now, recorded.factory).run(args)
  CliRun.new(code, stdout.to_s, stderr.to_s)
end

describe "donico-manager repos status, diff, pull and gc" do
  {"status", "diff", "pull", "gc"}.each do |command|
    it "runs git #{command} once in each cloned repository, as the working directory of its runner" do
      with_fleet(fleet_yaml) do |env|
        clone(env, "grafana", "traefik")
        recorded = Recorded.new
        run = run_recorded(env, ["repos", command], recorded)

        run.code.should eq 0
        run.stderr.should be_empty
        run.stdout.should eq [
          SEPARATOR, "Enter in grafana", SEPARATOR, "",
          "ruby: not cloned, skipping",
          SEPARATOR, "Enter in traefik", SEPARATOR, "",
        ].join('\n') + "\n"
        recorded.runners.map { |(dir, _)| dir }.should eq [
          File.join(env.dir, "docker-images", "grafana"), File.join(env.dir, "docker-images", "traefik"),
        ]
        recorded.runners.each do |(_, runner)|
          calls = runner.calls
          calls.size.should eq 1
          calls[0].kind.should eq :system
          calls[0].command.should eq "git"
          calls[0].args.should eq [command]
        end
      end
    end
  end

  it "runs only in the repository named" do
    with_fleet(fleet_yaml) do |env|
      clone(env, "grafana", "ruby")
      recorded = Recorded.new
      run = run_recorded(env, ["repos", "status", "ruby"], recorded)

      run.code.should eq 0
      run.stdout.should eq [SEPARATOR, "Enter in ruby", SEPARATOR, ""].join('\n') + "\n"
      recorded.runners.map { |(dir, _)| File.basename(dir) }.should eq ["ruby"]
    end
  end

  it "reports the failures after the sweep, on stdout and without prefix, with status 1" do
    with_fleet(fleet_yaml) do |env|
      clone(env, "grafana", "ruby", "traefik")
      recorded = Recorded.new({"grafana" => [128], "traefik" => [1]})
      run = run_recorded(env, ["repos", "pull"], recorded)

      run.code.should eq 1
      run.stderr.should be_empty
      run.stdout.should eq [
        SEPARATOR, "Enter in grafana", SEPARATOR, "",
        SEPARATOR, "Enter in ruby", SEPARATOR, "",
        SEPARATOR, "Enter in traefik", SEPARATOR, "",
        "2 repository/repositories failed.",
      ].join('\n') + "\n"
      recorded.runners.size.should eq 3
    end
  end

  it "does not count a repository that is not cloned" do
    with_fleet(fleet_yaml) do |env|
      run = run_recorded(env, ["repos", "gc"])

      run.code.should eq 0
      run.stdout.should eq "grafana: not cloned, skipping\nruby: not cloned, skipping\ntraefik: not cloned, skipping\n"
    end
  end

  it "refuses a repository the manifest does not declare" do
    with_fleet(fleet_yaml) do |env|
      run = run_recorded(env, ["repos", "status", "nope"])

      run.code.should eq 1
      run.stdout.should be_empty
      run.stderr.should eq "donico-manager: Unknown repository: nope\n"
    end
  end

  it "fails the repository whose git exits 128 and goes on, with the real runner" do
    with_fleet(fleet_yaml) do |env|
      clone(env, "grafana", "ruby")
      bin = File.join(env.dir, "bin")
      Dir.mkdir_p(bin)
      fake = File.join(bin, "git")
      File.write(fake, "#!/bin/sh\n[ \"$(basename \"$PWD\")\" = grafana ] && exit 128\nexit 0\n")
      File.chmod(fake, 0o755)
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      vars = {"PATH" => "#{bin}:/usr/bin:/bin"}
      code = Donico::Fleet::CLI.new(stdout, stderr, env.dir, vars, env.now).run(["repos", "status"])

      code.should eq 1
      stderr.to_s.should be_empty
      stdout.to_s.should eq [
        SEPARATOR, "Enter in grafana", SEPARATOR, "",
        SEPARATOR, "Enter in ruby", SEPARATOR, "",
        "traefik: not cloned, skipping",
        "1 repository/repositories failed.",
      ].join('\n') + "\n"
    end
  end
end

describe "donico-manager repos list" do
  it "says for each image, sorted, whether it is cloned" do
    with_fleet(fleet_yaml) do |env|
      clone(env, "ruby")
      run = run_recorded(env, ["repos", "list"])

      run.code.should eq 0
      run.stdout.should eq "Repository missing: grafana\nRepository exists: ruby\nRepository missing: traefik\n"
      run.stderr.should be_empty
    end
  end

  it "needs no process" do
    with_fleet(fleet_yaml) do |env|
      recorded = Recorded.new
      run_recorded(env, ["repos", "list"], recorded)

      recorded.runners.should be_empty
    end
  end

  it "colours the names on a terminal, and not when the fleet's variables hold NO_COLOR" do
    with_fleet(fleet_yaml) do |env|
      clone(env, "ruby")
      {({} of String => String) => "Repository missing: \e[31mgrafana\e[0m\nRepository exists: \e[32mruby\e[0m\nRepository missing: \e[31mtraefik\e[0m\n",
       {"NO_COLOR" => "1"} => "Repository missing: grafana\nRepository exists: ruby\nRepository missing: traefik\n"}.each do |vars, expected|
        stdout = TerminalIO.new
        Donico::Fleet::CLI.new(stdout, IO::Memory.new, env.dir, vars, env.now, Recorded.new.factory).run(["repos", "list"]).should eq 0
        stdout.to_s.should eq expected
      end
    end
  end

  it "reads NO_COLOR from the configuration repository's .env too" do
    with_fleet(fleet_yaml, {".env" => "NO_COLOR=1\n"}) do |env|
      clone(env, "ruby")
      stdout = TerminalIO.new
      Donico::Fleet::CLI.new(stdout, IO::Memory.new, env.dir, {} of String => String, env.now, Recorded.new.factory).run(["repos", "list"])
      stdout.to_s.should eq "Repository missing: grafana\nRepository exists: ruby\nRepository missing: traefik\n"
    end
  end
end

# An output that claims to be a terminal, for the colours.
private class TerminalIO < IO::Memory
  def tty? : Bool
    true
  end
end

describe "donico-manager repos clone" do
  it "creates the workspace, announces and clones each image that is not cloned, from the configuration repository" do
    with_fleet(fleet_yaml) do |env|
      clone(env, "grafana")
      recorded = Recorded.new
      run = run_recorded(env, ["repos", "clone"], recorded)

      run.code.should eq 0
      run.stderr.should be_empty
      run.stdout.should eq [
        "grafana: already cloned, skipping",
        "Cloning ruby",
        "Cloning traefik",
      ].join('\n') + "\n"
      Dir.exists?(File.join(env.dir, "docker-images")).should be_true
      calls = recorded.runners.flat_map { |(_, runner)| runner.calls }
      calls.map { |call| {call.kind, call.command, call.args} }.should eq [
        {:system, "git", ["clone", "git@example.org:factory/images/ruby.git", File.join(env.dir, "docker-images", "ruby")]},
        {:system, "git", ["clone", "git@example.org:factory/images/traefik.git", File.join(env.dir, "docker-images", "traefik")]},
      ]
      recorded.runners.each { |(dir, _)| dir.should eq env.dir }
    end
  end

  it "clones the one image named" do
    with_fleet(fleet_yaml) do |env|
      recorded = Recorded.new
      run = run_recorded(env, ["repos", "clone", "ruby"], recorded)

      run.code.should eq 0
      run.stdout.should eq "Cloning ruby\n"
      recorded.runners.flat_map { |(_, runner)| runner.calls }.map(&.args).should eq [
        ["clone", "git@example.org:factory/images/ruby.git", File.join(env.dir, "docker-images", "ruby")],
      ]
    end
  end

  it "counts the clones that failed, reports them and goes on" do
    with_fleet(fleet_yaml) do |env|
      recorded = Recorded.new({File.basename(env.dir) => [128, 0, 1]})
      run = run_recorded(env, ["repos", "clone"], recorded)

      run.code.should eq 1
      run.stdout.should eq "Cloning grafana\nCloning ruby\nCloning traefik\n2 repository/repositories failed.\n"
      recorded.runners.flat_map { |(_, runner)| runner.calls }.size.should eq 3
    end
  end

  it "refuses a repository the manifest does not declare, before creating the workspace" do
    with_fleet(fleet_yaml) do |env|
      run = run_recorded(env, ["repos", "clone", "nope"])

      run.code.should eq 1
      run.stderr.should eq "donico-manager: Unknown repository: nope\n"
      Dir.exists?(File.join(env.dir, "docker-images")).should be_false
    end
  end
end

describe "donico-manager repos check-security-spec" do
  it "says OK or MISSING for each cloned repository, and fails when one is missing" do
    with_fleet(fleet_yaml, {"docker-images/grafana/test/default/controls/security_spec.rb" => "control 'x'\n"}) do |env|
      clone(env, "ruby")
      run = run_recorded(env, ["repos", "check-security-spec"])

      run.code.should eq 1
      run.stdout.should eq "OK: grafana\nMISSING: ruby\n"
      run.stderr.should be_empty
    end
  end

  it "succeeds when every cloned repository has the control, ignoring the ones not cloned" do
    files = {
      "docker-images/grafana/test/default/controls/security_spec.rb" => "",
      "docker-images/ruby/test/default/controls/security_spec.rb"    => "",
    }
    with_fleet(fleet_yaml, files) do |env|
      run = run_recorded(env, ["repos", "check-security-spec"])

      run.code.should eq 0
      run.stdout.should eq "OK: grafana\nOK: ruby\n"
    end
  end

  it "counts a directory of that name as missing" do
    with_fleet(fleet_yaml) do |env|
      Dir.mkdir_p(File.join(env.dir, "docker-images", "ruby", "test", "default", "controls", "security_spec.rb"))
      run = run_recorded(env, ["repos", "check-security-spec"])

      run.code.should eq 1
      run.stdout.should eq "MISSING: ruby\n"
    end
  end

  it "says so when nothing is cloned" do
    with_fleet(fleet_yaml) do |env|
      run = run_recorded(env, ["repos", "check-security-spec"])

      run.code.should eq 0
      run.stdout.should eq "No cloned repository.\n"
    end
  end
end

private OPENER = {% if flag?(:darwin) %} "open" {% else %} "xdg-open" {% end %}

private def readme(env : Donico::Env, image : String, body : String) : Nil
  dir = File.join(env.dir, "docker-images", image)
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "README.md"), body)
end

private def detached(recorded : Recorded) : Array({Symbol, String, Array(String)})
  recorded.runners.flat_map { |(_, runner)| runner.calls }.map { |call| {call.kind, call.command, call.args} }
end

describe "donico-manager repos open-upstream" do
  it "opens the upstream URL found on a README line that mentions it, from the configuration repository, quietly" do
    with_fleet(fleet_yaml) do |env|
      readme(env, "grafana", "# grafana\n\nUpstream: [grafana](https://github.com/grafana/grafana)\n")
      recorded = Recorded.new
      run = run_recorded(env, ["repos", "open-upstream"], recorded)

      run.code.should eq 0
      run.stdout.should be_empty
      run.stderr.should be_empty
      detached(recorded).should eq [{:detach, OPENER, ["https://github.com/grafana/grafana"]}]
      recorded.envs.map(&.dir).should eq [env.dir]
      recorded.envs[0].vars["DONICO_QUIET"]?.should eq "1"
    end
  end

  it "opens each URL once, however many READMEs repeat it, in the order of the README paths" do
    with_fleet(fleet_yaml) do |env|
      # Created in an order that is not the sorted one, each with a URL of
      # its own first: the expected list depends on the README order.
      readme(env, "traefik", "upstream (https://github.com/o/shared)\nUPSTREAM (http://example.org/t)\n")
      readme(env, "ruby", "upstream (https://github.com/o/r)\n")
      readme(env, "grafana", "upstream (https://github.com/o/g)\nupstream (https://github.com/o/shared)\nnot this one (https://github.com/o/q)\n")
      readme(env, "alloy", "Upstream: (https://github.com/o/a)\n")
      readme(env, "zeta", "upstream (https://github.com/o/z)\n")
      readme(env, "beta", "upstream (https://github.com/o/b)\n")
      recorded = Recorded.new
      run_recorded(env, ["repos", "open-upstream"], recorded).code.should eq 0

      detached(recorded).should eq [
        {:detach, OPENER, ["https://github.com/o/a"]},
        {:detach, OPENER, ["https://github.com/o/b"]},
        {:detach, OPENER, ["https://github.com/o/g"]},
        {:detach, OPENER, ["https://github.com/o/shared"]},
        {:detach, OPENER, ["https://github.com/o/r"]},
        {:detach, OPENER, ["http://example.org/t"]},
        {:detach, OPENER, ["https://github.com/o/z"]},
      ]
    end
  end

  it "takes the first link of a line, and only a parenthesised http(s) one" do
    with_fleet(fleet_yaml) do |env|
      readme(env, "ruby", "upstream [a](https://a.example/x) [b](https://b.example/y)\nupstream: ftp (ftp://c.example/z)\nupstream https://d.example\n")
      recorded = Recorded.new
      run_recorded(env, ["repos", "open-upstream"], recorded).code.should eq 0

      detached(recorded).should eq [{:detach, OPENER, ["https://a.example/x"]}]
    end
  end

  it "reads every README of the workspace, declared or not" do
    with_fleet(fleet_yaml) do |env|
      readme(env, "undeclared", "Upstream: (https://github.com/o/undeclared)\n")
      recorded = Recorded.new
      run_recorded(env, ["repos", "open-upstream"], recorded).code.should eq 0

      detached(recorded).should eq [{:detach, OPENER, ["https://github.com/o/undeclared"]}]
    end
  end

  it "reads only the README of the repository named" do
    with_fleet(fleet_yaml) do |env|
      readme(env, "grafana", "upstream (https://github.com/o/grafana)\n")
      readme(env, "ruby", "upstream (https://github.com/o/ruby)\n")
      recorded = Recorded.new
      run_recorded(env, ["repos", "open-upstream", "ruby"], recorded).code.should eq 0

      detached(recorded).should eq [{:detach, OPENER, ["https://github.com/o/ruby"]}]
    end
  end

  it "says so when no README names one, and starts nothing" do
    with_fleet(fleet_yaml) do |env|
      readme(env, "grafana", "# grafana\n\nNothing to see here.\n")
      recorded = Recorded.new
      run = run_recorded(env, ["repos", "open-upstream"], recorded)

      run.code.should eq 0
      run.stdout.should eq "No upstream URL found in the cloned READMEs.\n"
      run.stderr.should be_empty
      recorded.runners.should be_empty
    end
  end

  it "says so when the repository named has no README" do
    with_fleet(fleet_yaml) do |env|
      readme(env, "grafana", "upstream (https://github.com/o/grafana)\n")
      run = run_recorded(env, ["repos", "open-upstream", "traefik"])

      run.code.should eq 0
      run.stdout.should eq "No upstream URL found in the cloned READMEs.\n"
    end
  end

  it "refuses a repository the manifest does not declare" do
    with_fleet(fleet_yaml) do |env|
      run = run_recorded(env, ["repos", "open-upstream", "nope"])

      run.code.should eq 1
      run.stdout.should be_empty
      run.stderr.should eq "donico-manager: Unknown repository: nope\n"
    end
  end

  it "reports a missing opener as one line, with the real runner" do
    with_fleet(fleet_yaml) do |env|
      readme(env, "grafana", "upstream (https://github.com/o/grafana)\n")
      empty = File.join(env.dir, "empty")
      Dir.mkdir_p(empty)
      run = run_fleet_in(env.dir, ["repos", "open-upstream"], {"PATH" => empty})

      run.code.should eq 1
      run.stdout.should be_empty
      run.stderr.should eq "donico-manager: #{OPENER} not found in PATH\n"
    end
  end
end

private def lint_args(dir : String, image : String, dockerfile : String = "/app/Dockerfile") : Array(String)
  ["run", "--pull", "always", "--rm", "-e", "MISE_IGNORED_CONFIG_PATHS=/app/mise.toml",
   "-v", "#{dir}:/app", image, "hadolint", dockerfile]
end

private def donico_yml(name : String, extra : String = "") : String
  "registry: r.example\nimage_name: #{name}\n#{extra}matrix:\n  - {version: \"1\", distro: d}\n"
end

describe "donico-manager repos check-hadolint" do
  it "lints each cloned repository in process, inside the sweep's lines, as its project directory and with its own tool image" do
    files = {
      "docker-images/grafana/donico.yml" => donico_yml("grafana"),
      "docker-images/ruby/donico.yml"    => "registry: r.example\nimage_name: ruby\ndocker_linter: lint.example/hadolint:2\n" \
                                         "matrix:\n  - {version: \"1\", distro: d, dockerfile: dockerfiles/d/Dockerfile}\n",
    }
    with_fleet(fleet_yaml, files) do |env|
      recorded = Recorded.new
      run = run_recorded(env, ["repos", "check-hadolint"], recorded)

      run.code.should eq 0
      run.stderr.should be_empty
      run.stdout.should eq [
        SEPARATOR, "Enter in grafana", "Dockerfile is OK!", SEPARATOR, "",
        SEPARATOR, "Enter in ruby", "Dockerfile is OK!", SEPARATOR, "",
        "traefik: not cloned, skipping",
      ].join('\n') + "\n"
      grafana = File.join(env.dir, "docker-images", "grafana")
      ruby = File.join(env.dir, "docker-images", "ruby")
      recorded.runners.map { |(dir, _)| dir }.should eq [grafana, ruby]
      recorded.runners.map { |(_, runner)| runner.calls.map { |call| {call.kind, call.command, call.args} } }.should eq [
        [{:capture, "docker", lint_args(grafana, "r.example/hadolint:latest")}],
        [{:capture, "docker", lint_args(ruby, "lint.example/hadolint:2", "/app/dockerfiles/d/Dockerfile")}],
      ]
    end
  end

  it "keeps the lines its processes print (no DONICO_QUIET), and completes the fleet's variables with the repository's .env" do
    files = {
      "docker-images/ruby/donico.yml" => donico_yml("ruby"),
      "docker-images/ruby/.env"       => "FROM_REPO=yes\nFLEET=repo\n",
    }
    with_fleet(fleet_yaml, files) do |env|
      recorded = Recorded.new
      stdout = IO::Memory.new
      code = Donico::Fleet::CLI.new(stdout, IO::Memory.new, env.dir, {"FLEET" => "fleet"}, env.now, recorded.factory)
        .run(["repos", "check-hadolint", "ruby"])

      code.should eq 0
      recorded.envs.size.should eq 1
      recorded.envs[0].dir.should eq File.join(env.dir, "docker-images", "ruby")
      recorded.envs[0].vars.should eq({"FLEET" => "fleet", "FROM_REPO" => "yes"})
      recorded.envs[0].stdout.should be stdout
    end
  end

  it "fails a repository whose lint fails, with what the linter said, and goes on" do
    files = {
      "docker-images/grafana/donico.yml" => donico_yml("grafana"),
      "docker-images/ruby/donico.yml"    => donico_yml("ruby"),
    }
    with_fleet(fleet_yaml, files) do |env|
      recorded = Recorded.new({"grafana" => [1]}, {"grafana" => "DL3008 pin versions"})
      run = run_recorded(env, ["repos", "check-hadolint"], recorded)

      run.code.should eq 1
      run.stderr.should be_empty
      run.stdout.should eq [
        SEPARATOR, "Enter in grafana", "DL3008 pin versions", SEPARATOR, "",
        SEPARATOR, "Enter in ruby", "Dockerfile is OK!", SEPARATOR, "",
        "traefik: not cloned, skipping",
        "1 repository/repositories failed.",
      ].join('\n') + "\n"
    end
  end

  it "fails a repository whose donico.yml or .env donico refuses, with its message, and goes on" do
    files = {
      "docker-images/grafana/donico.yml" => "registry: r.example\nimage_name: grafana\nmatrix:\n  - version: 3.10\n",
      "docker-images/ruby/donico.yml"    => donico_yml("ruby"),
      "docker-images/ruby/.env"          => "just words\n",
      "docker-images/traefik/donico.yml" => donico_yml("traefik"),
    }
    with_fleet(fleet_yaml, files) do |env|
      recorded = Recorded.new
      run = run_recorded(env, ["repos", "check-hadolint"], recorded)

      run.code.should eq 1
      run.stdout.should eq [
        SEPARATOR, "Enter in grafana", SEPARATOR, "",
        SEPARATOR, "Enter in ruby", SEPARATOR, "",
        SEPARATOR, "Enter in traefik", "Dockerfile is OK!", SEPARATOR, "",
        "2 repository/repositories failed.",
      ].join('\n') + "\n"
      run.stderr.should eq [
        "donico-manager: donico.yml: matrix[0].version must be a quoted string (YAML read it as 3.1; quote it as written in the file)",
        "donico-manager: .env: line 1 is not KEY=VALUE",
      ].join('\n') + "\n"
      recorded.runners.flat_map { |(_, runner)| runner.calls }.size.should eq 1
    end
  end

  it "fails each repository when docker is missing, with the real runner, announcing the call, and goes on" do
    files = {
      "docker-images/grafana/donico.yml" => donico_yml("grafana"),
      "docker-images/ruby/donico.yml"    => donico_yml("ruby"),
    }
    with_fleet(fleet_yaml, files) do |env|
      empty = File.join(env.dir, "empty")
      Dir.mkdir_p(empty)
      run = run_fleet_in(env.dir, ["repos", "check-hadolint"], {"PATH" => empty})

      grafana = File.join(env.dir, "docker-images", "grafana")
      ruby = File.join(env.dir, "docker-images", "ruby")
      run.code.should eq 1
      run.stdout.should eq [
        SEPARATOR, "Enter in grafana", "run_cmd: docker #{lint_args(grafana, "r.example/hadolint:latest").join(' ')}", SEPARATOR, "",
        SEPARATOR, "Enter in ruby", "run_cmd: docker #{lint_args(ruby, "r.example/hadolint:latest").join(' ')}", SEPARATOR, "",
        "traefik: not cloned, skipping",
        "2 repository/repositories failed.",
      ].join('\n') + "\n"
      run.stderr.should eq "donico-manager: docker not found in PATH\ndonico-manager: docker not found in PATH\n"
    end
  end

  it "fails a repository without donico.yml" do
    with_fleet(fleet_yaml) do |env|
      clone(env, "ruby")
      run = run_recorded(env, ["repos", "check-hadolint", "ruby"])

      run.code.should eq 1
      run.stdout.should eq [SEPARATOR, "Enter in ruby", SEPARATOR, "", "1 repository/repositories failed."].join('\n') + "\n"
      run.stderr.should eq "donico-manager: donico.yml not found in #{File.join(env.dir, "docker-images", "ruby")}\n"
    end
  end

  it "refuses a repository the manifest does not declare" do
    with_fleet(fleet_yaml) do |env|
      run = run_recorded(env, ["repos", "check-hadolint", "nope"])

      run.code.should eq 1
      run.stdout.should be_empty
      run.stderr.should eq "donico-manager: Unknown repository: nope\n"
    end
  end
end

describe "the arguments of the nine repos commands" do
  {"list", "check-security-spec", "status", "diff", "pull", "gc", "clone", "open-upstream", "check-hadolint"}.each do |command|
    it "refuses an unknown option after #{command}" do
      with_fleet(fleet_yaml) do |env|
        recorded = Recorded.new
        run = run_recorded(env, ["repos", command, "--nope"], recorded)

        run.code.should eq 1
        run.stdout.should be_empty
        run.stderr.should eq "donico-manager: unknown option: --nope\n"
        recorded.runners.should be_empty
        Dir.exists?(File.join(env.dir, "docker-images")).should be_false
      end
    end

    it "refuses an unknown option after the repository of #{command}" do
      next if {"list", "check-security-spec"}.includes?(command)
      with_fleet(fleet_yaml) do |env|
        run = run_recorded(env, ["repos", command, "ruby", "--nope"])

        run.code.should eq 1
        run.stderr.should eq "donico-manager: unknown option: --nope\n"
      end
    end
  end

  {"list", "check-security-spec"}.each do |command|
    it "refuses any argument after #{command}" do
      with_fleet(fleet_yaml) do |env|
        run = run_recorded(env, ["repos", command, "ruby"])

        run.code.should eq 1
        run.stdout.should be_empty
        run.stderr.should eq "donico-manager: unexpected argument: ruby\n"
      end
    end
  end

  {"status", "diff", "pull", "gc", "clone", "open-upstream", "check-hadolint"}.each do |command|
    it "refuses a second repository after #{command}" do
      with_fleet(fleet_yaml) do |env|
        recorded = Recorded.new
        run = run_recorded(env, ["repos", command, "ruby", "grafana"], recorded)

        run.code.should eq 1
        run.stdout.should be_empty
        run.stderr.should eq "donico-manager: unexpected argument: grafana\n"
        recorded.runners.should be_empty
      end
    end
  end
end

private BINARY = File.expand_path(File.join(__DIR__, "..", "..", "..", "bin", "donico-manager"))
private ROOT   = File.expand_path(File.join(__DIR__, "..", "..", ".."))

# `crystal spec` compiles the specs, not bin/donico: refuse to run on a binary
# older than one of its sources (same guard as binary_spec).
private def stale_source : String?
  built = File.info(File.join(ROOT, "bin", "donico")).modification_time
  sources = Dir.glob(File.join(ROOT, "src", "**", "*")) + [File.join(ROOT, "shard.yml")]
  sources.select { |path| File.file?(path) }.find { |path| File.info(path).modification_time > built }
end

describe "donico-manager repos status, through the compiled binary" do
  it "interleaves the separators and what git prints, and announces no process" do
    stale = stale_source
    stale.should be_nil, "bin/donico is older than #{stale}: run `mise dev:build`"

    with_fleet(fleet_yaml) do |env|
      clone(env, "grafana", "ruby")
      fake_dir = File.join(env.dir, "fake")
      Dir.mkdir_p(fake_dir)
      fake = File.join(fake_dir, "git")
      File.write(fake, "#!/bin/sh\necho \"git says $* in $(basename \"$PWD\")\"\n")
      File.chmod(fake, 0o755)
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(BINARY, ["repos", "status"], env: {"PATH" => "#{fake_dir}:/usr/bin:/bin"}, clear_env: true,
        chdir: env.dir, output: stdout, error: stderr)

      status.exit_code.should eq 0
      stderr.to_s.should be_empty
      stdout.to_s.should eq [
        SEPARATOR, "Enter in grafana", "git says status in grafana", SEPARATOR, "",
        SEPARATOR, "Enter in ruby", "git says status in ruby", SEPARATOR, "",
        "traefik: not cloned, skipping",
      ].join('\n') + "\n"
      stdout.to_s.should_not contain "with_exit_status"
    end
  end
end
