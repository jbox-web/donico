require "../spec_helper"

# One row with a secret env and a secret file whose src is an HCL reference
# (bake resolves it, donico must not stat it), plus login_env.
private YAML_FULL = <<-YAML
  registry: registry.example.net/images/base
  image_name: foo-bar
  matrix:
    - version: "1.0.0"
      distro: buster
      build_args:
        - NODEJS_VERSION=14.17.3
      login_env: [A, B]
      secret_envs:
        - id: GITHUB_TOKEN
      secret_files:
        - id: aws
          src: "${HOME}/.aws/credentials"
  YAML

private YAML_MINIMAL = <<-YAML
  registry: registry.example.net/images/base
  image_name: foo
  matrix:
    - version: latest
      distro: buster
  YAML

# The text printed after an unknown task for YAML_MINIMAL: the section 6.1
# commands, `help` and the additions, and the five tasks of the one row, sorted.
private VALID_TASKS = <<-TEXT
  Valid tasks:
    buster:latest:build
    buster:latest:clean
    buster:latest:login
    buster:latest:push
    buster:latest:test
    generate-files
    help
    image-builder
    inspec
    licenses
    lint-dockerfile
    matrix
    version

  TEXT

# No CI_COMMIT_TIMESTAMP: the build date is the fixed clock of with_project.
private TS = {} of String => String

private def image_for(env : Donico::Env) : Donico::Image
  Donico::Image.all(Donico::Config.load(env)).first
end

describe Donico::Tasks::Build do
  # BUILD_DATE is the one value the bakefile reads from the environment (its
  # `variable "BUILD_DATE"`); the other args are written in it. Exporting them
  # all, as the gem did, let an arg named PATH or DOCKER_HOST reconfigure the
  # docker client itself.
  it "replaces the process with buildx bake on the build target, BUILD_DATE alone as environment" do
    with_project(YAML_FULL, vars: TS.merge({"GITHUB_TOKEN" => "x"})) do |env|
      runner = RecordingRunner.new.script(7)

      code = Donico::Tasks::Build.new(image_for(env), env, runner).run

      code.should eq 7
      runner.calls.size.should eq 1
      call = runner.calls.first
      call.kind.should eq :exec
      call.command.should eq "docker"
      call.args.should eq ["buildx", "bake", "buster-1-0-0-build"]
      call.env.should eq({"BUILD_DATE" => "20260731"})
    end
  end

  it "builds a minimal row" do
    with_project(YAML_MINIMAL, vars: TS) do |env|
      runner = RecordingRunner.new

      Donico::Tasks::Build.new(image_for(env), env, runner).run.should eq 0

      call = runner.calls.first
      call.args.should eq ["buildx", "bake", "buster-latest-build"]
      call.env.should eq({"BUILD_DATE" => "20260731"})
    end
  end

  it "names the unset secret variable and calls nothing" do
    with_project(YAML_FULL, vars: TS) do |env|
      runner = RecordingRunner.new

      error = expect_raises(Donico::EnvironmentError) do
        Donico::Tasks::Build.new(image_for(env), env, runner).run
      end

      error.message.should eq %(secret "GITHUB_TOKEN" is declared in secret_envs but the variable GITHUB_TOKEN is not set)
      runner.calls.should be_empty
    end
  end

  it "counts a secret variable that is set but empty in env.vars as set" do
    with_project(YAML_FULL, vars: TS.merge({"GITHUB_TOKEN" => ""})) do |env|
      runner = RecordingRunner.new

      # Set but empty counts as set, as the gem's ENV.key? did.
      Donico::Tasks::Build.new(image_for(env), env, runner).run.should eq 0
      runner.calls.size.should eq 1
    end
  end

  it "reports a missing secret file source" do
    yaml = YAML_MINIMAL + "\n    secret_files:\n      - id: aws\n        src: /nope/credentials\n"
    with_project(yaml, vars: TS) do |env|
      runner = RecordingRunner.new

      error = expect_raises(Donico::EnvironmentError) do
        Donico::Tasks::Build.new(image_for(env), env, runner).run
      end

      error.message.should eq %(secret "aws" is declared in secret_files but its src "/nope/credentials" does not exist)
      runner.calls.should be_empty
    end
  end

  it "accepts an existing absolute source" do
    with_project(YAML_MINIMAL, files: {"creds" => "x"}, vars: TS) do |env|
      yaml = YAML_MINIMAL + "\n    secret_files:\n      - id: aws\n        src: #{File.join(env.dir, "creds")}\n"
      File.write(File.join(env.dir, "donico.yml"), yaml)
      runner = RecordingRunner.new

      Donico::Tasks::Build.new(image_for(env), env, runner).run.should eq 0
    end
  end

  it "resolves a relative source against the project directory" do
    yaml = YAML_MINIMAL + "\n    secret_files:\n      - id: aws\n        src: secrets/creds\n"
    with_project(yaml, files: {"secrets/creds" => "x"}, vars: TS) do |env|
      runner = RecordingRunner.new

      Donico::Tasks::Build.new(image_for(env), env, runner).run.should eq 0
      runner.calls.size.should eq 1
    end
  end

  it "does not check a source holding an HCL reference" do
    with_project(YAML_FULL, vars: TS.merge({"GITHUB_TOKEN" => "x"})) do |env|
      runner = RecordingRunner.new

      Donico::Tasks::Build.new(image_for(env), env, runner).run.should eq 0
    end
  end

  it "reports every missing secret, one per line, envs first then files" do
    yaml = YAML_MINIMAL + "\n" + [
      "    secret_envs:",
      "      - id: TOKEN_B",
      "      - id: TOKEN_A",
      "    secret_files:",
      "      - id: f1",
      "        src: /nope/one",
      "      - id: f2",
      "        src: /nope/two",
      "",
    ].join("\n")
    with_project(yaml, vars: TS) do |env|
      runner = RecordingRunner.new

      error = expect_raises(Donico::EnvironmentError) do
        Donico::Tasks::Build.new(image_for(env), env, runner).run
      end

      error.message.should eq [
        %(secret "TOKEN_B" is declared in secret_envs but the variable TOKEN_B is not set),
        %(secret "TOKEN_A" is declared in secret_envs but the variable TOKEN_A is not set),
        %(secret "f1" is declared in secret_files but its src "/nope/one" does not exist),
        %(secret "f2" is declared in secret_files but its src "/nope/two" does not exist),
      ].join("\n")
      runner.calls.should be_empty
    end
  end
end

describe Donico::Tasks::Push do
  it "replaces the process with buildx bake on the push target" do
    with_project(YAML_FULL, vars: TS.merge({"GITHUB_TOKEN" => "x"})) do |env|
      runner = RecordingRunner.new

      Donico::Tasks::Push.new(image_for(env), env, runner).run.should eq 0

      call = runner.calls.first
      call.kind.should eq :exec
      call.command.should eq "docker"
      call.args.should eq ["buildx", "bake", "buster-1-0-0-push"]
      call.env.should eq({"BUILD_DATE" => "20260731"})
    end
  end

  it "applies the same secret check and calls nothing" do
    with_project(YAML_FULL, vars: TS) do |env|
      runner = RecordingRunner.new

      expect_raises(Donico::EnvironmentError, /GITHUB_TOKEN/) do
        Donico::Tasks::Push.new(image_for(env), env, runner).run
      end
      runner.calls.should be_empty
    end
  end
end

describe Donico::Tasks::Clean do
  it "removes the build tag and prints nothing more on success" do
    with_project(YAML_MINIMAL, vars: TS) do |env|
      runner = RecordingRunner.new

      Donico::Tasks::Clean.new(image_for(env), env, runner).run.should eq 0

      call = runner.calls.first
      call.kind.should eq :capture
      call.command.should eq "docker"
      call.args.should eq ["rmi", "foo/latest/buster:20260731"]
      env.stdout.to_s.should be_empty
    end
  end

  it "prints the captured text and returns 1 when docker fails" do
    with_project(YAML_MINIMAL, vars: TS) do |env|
      runner = RecordingRunner.new.script(1, "Error: No such image: foo/latest/buster:20260731")

      Donico::Tasks::Clean.new(image_for(env), env, runner).run.should eq 1

      env.stdout.to_s.should eq "Error: No such image: foo/latest/buster:20260731\n"
    end
  end
end

describe Donico::Tasks::Login do
  it "passes each login_env variable name to the container" do
    with_project(YAML_FULL, vars: TS) do |env|
      runner = RecordingRunner.new

      Donico::Tasks::Login.new(image_for(env), env, runner).run.should eq 0

      call = runner.calls.first
      call.kind.should eq :exec
      call.command.should eq "docker"
      call.args.should eq ["run", "-it", "--rm", "-e", "A", "-e", "B", "foo-bar/1.0.0/buster:20260731", "/bin/bash"]
      call.env.should be_empty
    end
  end

  it "adds no -e without login_env" do
    with_project(YAML_MINIMAL, vars: TS) do |env|
      runner = RecordingRunner.new

      Donico::Tasks::Login.new(image_for(env), env, runner).run

      runner.calls.first.args.should eq ["run", "-it", "--rm", "foo/latest/buster:20260731", "/bin/bash"]
    end
  end
end

# Runs the CLI in the project directory with a recording runner injected, the
# way the binary would reach the real one.
private def run_with_recorder(env : Donico::Env, args : Array(String), runner : RecordingRunner) : CliRun
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  factory = ->(_env : Donico::Env) { runner.as(Donico::Runner) }
  code = Donico::CLI.new(stdout, stderr, env.dir, env.vars, env.now, factory).run(args)
  CliRun.new(code, stdout.to_s, stderr.to_s)
end

describe "Donico::CLI matrix tasks" do
  it "dispatches <distro>:<version>:build to the row found by distro and version" do
    with_project(YAML_FULL, vars: {"GITHUB_TOKEN" => "x"}) do |env|
      runner = RecordingRunner.new.script(3)

      run = run_with_recorder(env, ["buster:1.0.0:build"], runner)

      run.code.should eq 3
      runner.calls.first.args.should eq ["buildx", "bake", "buster-1-0-0-build"]
    end
  end

  it "dispatches push, clean and login" do
    with_project(YAML_FULL, vars: {"GITHUB_TOKEN" => "x"}) do |env|
      runner = RecordingRunner.new

      run_with_recorder(env, ["buster:1.0.0:push"], runner).code.should eq 0
      run_with_recorder(env, ["buster:1.0.0:clean"], runner).code.should eq 0
      run_with_recorder(env, ["buster:1.0.0:login"], runner).code.should eq 0

      # The whole command of each: `build` and `push` both start with
      # "buildx", and only the target tells a push from a build.
      runner.calls.map(&.args.first(3)).should eq [
        ["buildx", "bake", "buster-1-0-0-push"],
        ["rmi", "foo-bar/1.0.0/buster:20260731"],
        ["run", "-it", "--rm"],
      ]
    end
  end

  # A task name is `<distro>:<version>:<action>`. Neither part can hold a
  # colon (Config refuses it), so a name with a third one answers to nothing.
  it "rejects a name with a third colon" do
    yaml = "registry: r\nimage_name: foo\nmatrix:\n  - {version: \"1\", distro: buster}\n"
    with_project(yaml) do |env|
      runner = RecordingRunner.new

      run = run_with_recorder(env, ["buster:1:2:build"], runner)

      run.code.should eq 1
      run.stderr.should start_with "donico: unknown task: buster:1:2:build\n"
      runner.calls.should be_empty
    end
  end

  it "prefixes every line of several missing secrets, one per secret" do
    yaml = [
      "registry: r", "image_name: foo", "matrix:", "  - version: \"1\"", "    distro: buster",
      "    secret_envs:", "      - id: TOKEN_A", "      - id: TOKEN_B", "",
    ].join("\n")
    with_project(yaml) do |env|
      runner = RecordingRunner.new

      run = run_with_recorder(env, ["buster:1:build"], runner)

      run.code.should eq 1
      run.stderr.should eq [
        %(donico: secret "TOKEN_A" is declared in secret_envs but the variable TOKEN_A is not set),
        %(donico: secret "TOKEN_B" is declared in secret_envs but the variable TOKEN_B is not set),
        "",
      ].join("\n")
      runner.calls.should be_empty
    end
  end

  it "prints a secret error as donico: <message> and calls nothing" do
    with_project(YAML_FULL) do |env|
      runner = RecordingRunner.new

      run = run_with_recorder(env, ["buster:1.0.0:build"], runner)

      run.code.should eq 1
      run.stderr.should eq %(donico: secret "GITHUB_TOKEN" is declared in secret_envs but the variable GITHUB_TOKEN is not set\n)
      runner.calls.should be_empty
    end
  end

  it "prints the captured text of a failed clean and exits 1" do
    with_project(YAML_MINIMAL) do |env|
      runner = RecordingRunner.new.script(1, "boom")

      run = run_with_recorder(env, ["buster:latest:clean"], runner)

      run.code.should eq 1
      run.stdout.should eq "boom\n"
    end
  end

  it "rejects an unknown row" do
    with_project(YAML_MINIMAL) do |env|
      run = run_with_recorder(env, ["bullseye:latest:build"], RecordingRunner.new)

      run.code.should eq 1
      run.stderr.should eq "donico: unknown task: bullseye:latest:build\n#{VALID_TASKS}"
    end
  end

  it "rejects an unknown action, and tag for now" do
    with_project(YAML_MINIMAL) do |env|
      ["buster:latest:nope", "buster:latest:tag"].each do |name|
        run = run_with_recorder(env, [name], RecordingRunner.new)

        run.code.should eq 1
        run.stderr.should eq "donico: unknown task: #{name}\n#{VALID_TASKS}"
      end
    end
  end

  it "dispatches <distro>:<version>:test to the harness with the Inspec image of the tools registry" do
    with_project(YAML_MINIMAL) do |env|
      runner = RecordingRunner.new.script(0, "cid").script(4)

      run = run_with_recorder(env, ["buster:latest:test"], runner)

      run.code.should eq 4
      runner.calls[1].args.should contain "registry.example.net/images/base/inspec:latest"
      runner.calls[1].args.should contain "docker://cid"
    end
  end

  it "rejects a name without the two colons, listing the valid tasks" do
    with_project(YAML_MINIMAL) do |env|
      run = run_with_recorder(env, ["buster:build"], RecordingRunner.new)

      run.code.should eq 1
      run.stderr.should eq "donico: unknown task: buster:build\n#{VALID_TASKS}"
    end
  end

  it "rejects an extra argument after a matrix task" do
    with_project(YAML_MINIMAL) do |env|
      run = run_with_recorder(env, ["buster:latest:build", "extra"], RecordingRunner.new)

      run.code.should eq 1
      run.stderr.should eq "donico: unexpected argument: extra\n"
    end
  end
end

describe "Donico::CLI inspec" do
  it "runs the harness on the mode, the image and the inputs, with the Inspec image of the project" do
    with_project(YAML_MINIMAL) do |env|
      runner = RecordingRunner.new.script(0, "cid").script(6)

      run = run_with_recorder(env, ["inspec", "donico", "img:1", "a=1", "b"], runner)

      run.code.should eq 6
      runner.calls[0].args[3].should eq "img:1"
      runner.calls[1].args.should contain "registry.example.net/images/base/inspec:latest"
      runner.calls[1].args.last(3).should eq ["--input", "a=1", "b"]
      runner.calls[1].env.should eq({"a" => "1", "b" => "b"})
    end
  end

  it "takes an input that starts with a dash only after --" do
    with_project(YAML_MINIMAL) do |env|
      runner = RecordingRunner.new.script(0, "cid")

      run = run_with_recorder(env, ["inspec", "donico", "img", "--", "-x=1", "y=2"], runner)

      run.code.should eq 0
      runner.calls[1].args.last(3).should eq ["--input", "-x=1", "y=2"]
    end
  end

  it "rejects an input that starts with a dash without --" do
    with_project(YAML_MINIMAL) do |env|
      runner = RecordingRunner.new
      run = run_with_recorder(env, ["inspec", "donico", "img", "-x=1"], runner)

      run.code.should eq 1
      run.stderr.should eq "donico: unknown option: -x=1\n"
      runner.calls.should be_empty
    end
  end

  it "rejects an unknown mode before any call" do
    with_project(YAML_MINIMAL) do |env|
      runner = RecordingRunner.new
      run = run_with_recorder(env, ["inspec", "kaniko", "img"], runner)

      run.code.should eq 1
      run.stderr.should eq "donico: unknown inspec mode: kaniko (supported: donico)\n"
      runner.calls.should be_empty
    end
  end

  it "rejects an unknown mode before donico.yml is loaded" do
    with_tmp_dir do |dir|
      run = run_cli_in(dir, ["inspec", "kaniko", "img"])

      run.code.should eq 1
      run.stderr.should eq "donico: unknown inspec mode: kaniko (supported: donico)\n"
    end
  end

  it "asks for the mode and the image" do
    with_project(YAML_MINIMAL) do |env|
      ["inspec", "inspec donico"].each do |line|
        run = run_with_recorder(env, line.split, RecordingRunner.new)

        run.code.should eq 1
        run.stderr.should eq "donico: usage: donico inspec <mode> <image> [inputs...] (an input starting with - goes after --)\n"
      end
    end
  end
end
