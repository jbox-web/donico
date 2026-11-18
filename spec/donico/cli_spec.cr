require "../spec_helper"

# The version the binary must print outside a release build: the one of
# shard.yml, read here from the file rather than written a second time. (The
# spec tasks of mise.toml empty DONICO_VERSION, which a release build sets.)
private SHARD_VERSION = YAML.parse(File.read(File.join(__DIR__, "..", "..", "shard.yml")))["version"].as_s

describe Donico::CLI do
  describe "version" do
    it "prints the bare version and succeeds" do
      with_tmp_dir do |dir|
        run = run_cli_in(dir, ["version"])

        run.code.should eq(0)
        run.stdout.should eq("#{SHARD_VERSION}\n")
        run.stderr.should be_empty
      end
    end
  end

  describe "--version" do
    it "prints the self-naming version line and succeeds" do
      with_tmp_dir do |dir|
        run = run_cli_in(dir, ["--version"])

        run.code.should eq(0)
        run.stdout.should match(/\Adonico #{Regex.escape(SHARD_VERSION)} \((unknown|[0-9a-f]{8}(-dirty)?), (linux|darwin)\/(amd64|arm64)\)\n\z/)
        run.stderr.should be_empty
      end
    end
  end

  describe "--help" do
    it "prints the usage on stdout and succeeds" do
      with_tmp_dir do |dir|
        run = run_cli_in(dir, ["--help"])

        run.code.should eq(0)
        run.stdout.should start_with("Usage: donico <task> [options]")
        run.stderr.should be_empty
      end
    end

    it "answers to -h as well" do
      with_tmp_dir do |dir|
        run = run_cli_in(dir, ["-h"])

        run.code.should eq(0)
        run.stdout.should eq run_cli_in(dir, ["--help"]).stdout
      end
    end

    it "names the task in the usage line when one was given" do
      with_tmp_dir do |dir|
        run_cli_in(dir, ["matrix", "--help"]).stdout.should start_with("Usage: donico matrix [options]")
      end
    end
  end

  describe "a `--` after a task that takes no argument" do
    it "refuses what follows it" do
      with_tmp_dir do |dir|
        run = run_cli_in(dir, ["matrix", "--", "x"])

        run.code.should eq(1)
        run.stderr.should eq("donico: unexpected argument: x\n")
      end
    end
  end

  describe "licenses" do
    it "prints every embedded notice in full, each under its own header" do
      with_tmp_dir do |dir|
        run = run_cli_in(dir, ["licenses"])

        run.code.should eq(0)
        run.stderr.should be_empty
        # licenses.manifest, which is tracked, lists what the folder holds.
        names = run.stdout.lines.select(&.starts_with?("==> ")).map(&.[4..-5])
        names.should eq ["clib-Apache-2.0.txt", "clib-Boehm-GC.txt", "clib-GCC-runtime-exception.txt",
                         "cookie_jar.txt", "crest.txt", "donico.txt", "http-client-digest_auth.txt",
                         "http_proxy.txt", "libyaml.txt", "musl.txt", "pcre2.txt", "termisu.txt", "zlib.txt"]
        # A sentence of the body of two of them: a header alone is not a notice.
        run.stdout.should contain "Permission is hereby granted, free of charge"
        run.stdout.should contain "Apache License"
      end
    end
  end

  describe "a reader that closed the pipe" do
    # `donico --help | head`: nobody is left to tell, and a backtrace on
    # stderr would be the only thing the user sees.
    it "ends with status 1 and prints nothing more" do
      with_tmp_dir do |dir|
        stdout = IO::Memory.new
        stdout.close
        stderr = IO::Memory.new

        Donico::CLI.new(stdout, stderr, dir).run(["--help"]).should eq 1
        stderr.to_s.should be_empty
      end
    end
  end

  describe "an unknown option" do
    it "reports it on stderr and fails" do
      with_tmp_dir do |dir|
        run = run_cli_in(dir, ["--nope"])

        run.code.should eq(1)
        run.stderr.should eq("donico: unknown option: --nope\n")
        run.stdout.should be_empty
      end
    end
  end
end

# Exposes the Env the CLI builds and the runner it picks, which no task
# consumes yet.
class EnvProbeCLI < Donico::CLI
  def probe : Donico::Env
    build_env
  end

  def probe_runner(env : Donico::Env) : Donico::Runner
    runner_for(env)
  end
end

describe "Donico::CLI environment" do
  it "completes the injected variables with the project's .env, injected ones winning" do
    with_tmp_dir do |dir|
      File.write(File.join(dir, ".env"), "A=from-file\nB=2\n")
      cli = EnvProbeCLI.new(IO::Memory.new, IO::Memory.new, dir, {"A" => "from-env"})

      env = cli.probe
      env.vars.should eq({"A" => "from-env", "B" => "2"})
      env.dir.should eq(dir)
    end
  end

  it "reports a malformed .env as donico: <message>, without the line's content" do
    with_tmp_dir do |dir|
      File.write(File.join(dir, ".env"), "A=1\njust words\n")
      run = run_cli_in(dir, ["image-builder"])

      run.code.should eq(1)
      run.stderr.should eq("donico: .env: line 2 is not KEY=VALUE\n")
      run.stdout.should be_empty
    end
  end

  it "does not read .env for version and licenses, like --version" do
    with_tmp_dir do |dir|
      File.write(File.join(dir, ".env"), "A=1\njust words\n")

      ["version", "licenses", "--version"].each do |arg|
        run = run_cli_in(dir, [arg])

        run.code.should eq(0)
        run.stderr.should be_empty
        run.stdout.should_not be_empty
      end
    end
  end

  it "names the extra word, not the task, in an unexpected argument" do
    with_tmp_dir do |dir|
      {
        ["matrix", "extra"]    => "extra",
        ["version", "extra"]   => "extra",
        ["matrix", "version"]  => "version",
        ["x:1:build", "extra"] => "extra",
      }.each do |args, word|
        run_cli_in(dir, args).stderr.should eq("donico: unexpected argument: #{word}\n")
      end
    end
  end
end

describe "Donico::CLI runner" do
  it "uses a Runner::Real when no factory is injected" do
    with_tmp_dir do |dir|
      cli = EnvProbeCLI.new(IO::Memory.new, IO::Memory.new, dir, {} of String => String)

      cli.probe_runner(cli.probe).should be_a(Donico::Runner::Real)
    end
  end

  it "uses the injected factory, handing it the Env" do
    with_tmp_dir do |dir|
      fake = RecordingRunner.new
      seen = nil.as(Donico::Env?)
      factory = ->(env : Donico::Env) do
        seen = env
        fake.as(Donico::Runner)
      end
      cli = EnvProbeCLI.new(IO::Memory.new, IO::Memory.new, dir, {"A" => "1"}, Time.utc, factory)
      env = cli.probe

      cli.probe_runner(env).should be(fake)
      seen.should eq(env)
    end
  end

  describe "generate-files" do
    it "writes both generated files and reports them" do
      yaml = "registry: r\nimage_name: foo\nmatrix:\n  - {version: \"1.0\", distro: buster}\n"
      with_project(yaml) do |env|
        run = run_cli_in(env.dir, ["generate-files"])

        run.code.should eq(0)
        run.stdout.should eq("GitlabCI Matrix file generated\nBakefile generated\n")
        File.exists?(File.join(env.dir, ".gitlab-ci", "extends", ".matrix.yml")).should be_true
        File.exists?(File.join(env.dir, "docker-bake.hcl")).should be_true
      end
    end

    it "fails on a missing donico.yml without writing anything" do
      with_tmp_dir do |dir|
        run = run_cli_in(dir, ["generate-files"])

        run.code.should eq(1)
        run.stderr.should eq("donico: donico.yml not found in #{dir}\n")
        Dir.children(dir).should be_empty
      end
    end
  end

  describe "image-builder" do
    it "prints bake" do
      with_project("registry: r\nimage_name: foo\n") do |env|
        run = run_cli_in(env.dir, ["image-builder"])

        run.code.should eq(0)
        run.stdout.should eq("bake\n")
      end
    end
  end

  describe "matrix" do
    # Runs `matrix` on a fixed clock and no process variables.
    matrix_output = ->(yaml : String) do
      out = ""
      with_project(yaml) do |env|
        stdout = IO::Memory.new
        now = Time.utc(2026, 7, 31, 23, 59, 59)
        code = Donico::CLI.new(stdout, IO::Memory.new, env.dir, {} of String => String, now).run(["matrix"])
        code.should eq(0)
        out = stdout.to_s
      end
      out
    end

    it "prints the resolved matrix as pretty JSON" do
      yaml = <<-YAML
        registry: r.example/base
        image_name: docker-in-docker
        matrix:
          - version: "1.2.3"
            distro: trixie
            tags: ["latest-%<distro>s", "%<version>s-%<distro>s"]
            build_args: ["FOO=bar"]
            test_args: ["Token=AbC=", "alpha=1"]
        YAML
      expected = <<-JSON + "\n"
        [
          {
            "name": "docker-in-docker",
            "version": "1.2.3",
            "distro": "trixie",
            "archs": [
              "linux/amd64"
            ],
            "dockerfile": "Dockerfile",
            "build_args": [
              "BUILD_DATE=20260731",
              "DISTRO_NAME=trixie",
              "DOCKER_IN_DOCKER_VERSION=1.2.3",
              "FOO=bar"
            ],
            "test_args": [
              "Token=AbC=",
              "alpha=1"
            ],
            "tags": [
              "latest-%<distro>s",
              "%<version>s-%<distro>s"
            ],
            "secret_envs": [],
            "secret_files": [],
            "test_variants": [],
            "login_env": [],
            "build_tag": "docker-in-docker/1.2.3/trixie:20260731",
            "prod_tags": [
              "r.example/base/docker-in-docker:1.2.3-trixie",
              "r.example/base/docker-in-docker:latest-trixie"
            ],
            "build_target": "trixie-1-2-3-build",
            "push_target": "trixie-1-2-3-push"
          }
        ]
        JSON
      matrix_output.call(yaml).should eq expected
    end

    it "prints the declared secrets, test variants and login variables" do
      yaml = <<-YAML
        registry: r.example/base
        image_name: foo
        matrix:
          - version: "1"
            distro: a
            secret_envs:
              - id: GITHUB_TOKEN
            test_variants:
              - ["alpha=1", "beta=2"]
            login_env: [REGISTRY_TOKEN]
        YAML
      row = JSON.parse(matrix_output.call(yaml))[0]
      row["secret_envs"].should eq JSON.parse(%([{"id": "GITHUB_TOKEN"}]))
      row["secret_files"].should eq JSON.parse("[]")
      row["test_variants"].should eq JSON.parse(%([["alpha=1", "beta=2"]]))
      row["login_env"].should eq JSON.parse(%(["REGISTRY_TOKEN"]))
      keys = row.as_h.keys
      keys[(keys.index!("tags") + 1)...keys.index!("build_tag")].should eq ["secret_envs", "secret_files", "test_variants", "login_env"]
    end

    it "prints an empty list for an empty matrix" do
      matrix_output.call("registry: r\nimage_name: foo\nmatrix: []\n").should eq "[]\n"
    end
  end
end

describe "Donico::CLI lint-dockerfile" do
  it "runs the linter image of the project on its Dockerfile, mounting the project directory" do
    with_project("registry: r.example\nimage_name: foo\nmatrix:\n  - {version: \"1\", distro: d}\n") do |env|
      runner = RecordingRunner.new
      factory = ->(_env : Donico::Env) { runner.as(Donico::Runner) }
      stdout = IO::Memory.new

      code = Donico::CLI.new(stdout, IO::Memory.new, env.dir, {} of String => String, Time.utc, factory).run(["lint-dockerfile"])

      code.should eq 0
      stdout.to_s.should eq "Dockerfile is OK!\n"
      runner.calls.map(&.args).should eq [[
        "run", "--pull", "always", "--rm", "-e", "MISE_IGNORED_CONFIG_PATHS=/app/mise.toml",
        "-v", "#{env.dir}:/app", "r.example/hadolint:latest", "hadolint", "/app/Dockerfile",
      ]]
    end
  end
end

# One row, trixie / 1.2.3 / linux/amd64: the fixture of the help and
# unknown-task examples.
private YAML_TRIXIE = "registry: r.example\nimage_name: foo\nmatrix:\n  - {version: \"1.2.3\", distro: trixie}\n"

private HELP_TRIXIE = <<-TEXT + "\n\n"
  Usage:

    donico generate-files      # Generate GitlabCI matrix and Bakefile
    donico image-builder       # Print the configured image builder
    donico inspec              # Run the Inspec harness on an image
    donico licenses            # Print the third-party notices embedded in this binary
    donico lint-dockerfile     # Lint Dockerfile
    donico matrix              # Print the resolved matrix as JSON
    donico trixie:1.2.3:build  # Build docker image for trixie/1.2.3 ["linux/amd64"]
    donico trixie:1.2.3:clean  # Clean docker image for trixie/1.2.3 ["linux/amd64"]
    donico trixie:1.2.3:login  # Login into docker image for trixie/1.2.3 ["linux/amd64"]
    donico trixie:1.2.3:push   # Push docker image for trixie/1.2.3 ["linux/amd64"]
    donico trixie:1.2.3:test   # Test docker image for trixie/1.2.3 ["linux/amd64"]
    donico version             # Version
  TEXT

private VALID_TASKS_TRIXIE = <<-TEXT
  Valid tasks:
    generate-files
    help
    image-builder
    inspec
    licenses
    lint-dockerfile
    matrix
    trixie:1.2.3:build
    trixie:1.2.3:clean
    trixie:1.2.3:login
    trixie:1.2.3:push
    trixie:1.2.3:test
    version
  TEXT

describe "Donico::CLI help" do
  it "prints the usage, one sorted line per task without help itself, then a blank line" do
    with_project(YAML_TRIXIE) do |env|
      run = run_cli_in(env.dir, ["help"])

      run.code.should eq 0
      run.stdout.should eq HELP_TRIXIE
      run.stderr.should be_empty
    end
  end

  it "is what runs when no task is given" do
    with_project(YAML_TRIXIE) do |env|
      run = run_cli_in(env.dir, [] of String)

      run.code.should eq 0
      run.stdout.should eq HELP_TRIXIE
    end
  end

  it "needs donico.yml, unlike --help" do
    with_tmp_dir do |dir|
      ["help", nil].each do |task|
        run = run_cli_in(dir, task ? [task] : [] of String)

        run.code.should eq 1
        run.stdout.should be_empty
        run.stderr.should eq "donico: donico.yml not found in #{dir}\n"
      end
    end
  end

  it "lists every row of the matrix with its archs as Ruby writes them, among the other tasks" do
    yaml = "registry: r\nimage_name: foo\nmatrix:\n  - {version: \"1\", distro: b, archs: [linux/amd64, linux/arm64]}\n  - {version: \"2\", distro: a}\n"
    expected = <<-TEXT + "\n\n"
      Usage:

        donico a:2:build        # Build docker image for a/2 ["linux/amd64"]
        donico a:2:clean        # Clean docker image for a/2 ["linux/amd64"]
        donico a:2:login        # Login into docker image for a/2 ["linux/amd64"]
        donico a:2:push         # Push docker image for a/2 ["linux/amd64"]
        donico a:2:test         # Test docker image for a/2 ["linux/amd64"]
        donico b:1:build        # Build docker image for b/1 ["linux/amd64", "linux/arm64"]
        donico b:1:clean        # Clean docker image for b/1 ["linux/amd64", "linux/arm64"]
        donico b:1:login        # Login into docker image for b/1 ["linux/amd64", "linux/arm64"]
        donico b:1:push         # Push docker image for b/1 ["linux/amd64", "linux/arm64"]
        donico b:1:test         # Test docker image for b/1 ["linux/amd64", "linux/arm64"]
        donico generate-files   # Generate GitlabCI matrix and Bakefile
        donico image-builder    # Print the configured image builder
        donico inspec           # Run the Inspec harness on an image
        donico licenses         # Print the third-party notices embedded in this binary
        donico lint-dockerfile  # Lint Dockerfile
        donico matrix           # Print the resolved matrix as JSON
        donico version          # Version
      TEXT
    with_project(yaml) do |env|
      run_cli_in(env.dir, ["help"]).stdout.should eq expected
    end
  end
end

describe "Donico::CLI unknown tasks" do
  ["trixie:9.9:build", "trixie:1.2.3:tag", "lint-commits", "nope", "trixie:build"].each do |name|
    it "rejects #{name} with the list of valid tasks" do
      with_project(YAML_TRIXIE) do |env|
        run = run_cli_in(env.dir, [name])

        run.code.should eq 1
        run.stdout.should be_empty
        run.stderr.should eq "donico: unknown task: #{name}\n" + VALID_TASKS_TRIXIE + "\n"
      end
    end
  end

  it "lets the missing donico.yml win over the unknown task" do
    with_tmp_dir do |dir|
      run = run_cli_in(dir, ["nope"])

      run.code.should eq 1
      run.stderr.should eq "donico: donico.yml not found in #{dir}\n"
    end
  end

  it "lets an invalid donico.yml win over the unknown task" do
    with_project("image_name: foo\n") do |env|
      run = run_cli_in(env.dir, ["nope"])

      run.code.should eq 1
      run.stderr.should eq "donico: donico.yml: missing required key: registry\n"
    end
  end
end

describe "Donico::CLI without donico.yml" do
  it "runs version, licenses and --help" do
    with_tmp_dir do |dir|
      [["version"], ["licenses"], ["--help"]].each do |args|
        run_cli_in(dir, args).code.should eq 0
      end
    end
  end

  it "fails every other task with the missing donico.yml message" do
    with_tmp_dir do |dir|
      ["generate-files", "image-builder", "lint-dockerfile", "matrix", "inspec donico img", "trixie:1.2.3:build"].each do |line|
        run = run_cli_in(dir, line.split(' '))

        run.code.should eq 1
        run.stderr.should eq "donico: donico.yml not found in #{dir}\n"
      end
    end
  end

  it "points --help users at the help task in one line" do
    with_tmp_dir do |dir|
      run_cli_in(dir, ["--help"]).stdout.should contain "`donico` alone runs `donico help`"
    end
  end
end

# A runner that fails the way the real one does when a command is missing.
private class MissingCommandRunner < RecordingRunner
  def capture(command : String, args : Array(String), env : Vars = Vars.new) : {Int32, String}
    raise Donico::EnvironmentError.new("#{command} not found in PATH")
  end
end

describe "Donico::CLI error reporting" do
  it "prints an EnvironmentError raised by a task as one line, without a backtrace" do
    with_project(YAML_TRIXIE) do |env|
      factory = ->(_env : Donico::Env) { MissingCommandRunner.new.as(Donico::Runner) }
      stderr = IO::Memory.new

      code = Donico::CLI.new(IO::Memory.new, stderr, env.dir, {} of String => String, Time.utc, factory).run(["lint-dockerfile"])

      code.should eq 1
      stderr.to_s.should eq "donico: docker not found in PATH\n"
    end
  end

  it "prints a ConfigError as one line, without a backtrace" do
    with_project("registry: r\nimage_name: foo\nmatrix: nope\n") do |env|
      run = run_cli_in(env.dir, ["help"])

      run.code.should eq 1
      run.stderr.should eq "donico: donico.yml: matrix must be a list of mappings\n"
    end
  end
end
