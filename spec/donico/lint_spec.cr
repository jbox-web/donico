require "../spec_helper"

private YAML_ONE = "registry: r\nimage_name: foo\nmatrix:\n  - version: \"1.0\"\n    distro: d\n"

# Two rows sharing a Dockerfile and a third one with its own: two lint runs.
private YAML_MANY = <<-YAML
  registry: r
  image_name: foo
  matrix:
    - {version: "1", distro: a, dockerfile: dockerfiles/3.1/Dockerfile}
    - {version: "2", distro: b, dockerfile: dockerfiles/3.1/Dockerfile}
    - {version: "3", distro: c, dockerfile: dockerfiles/3.2/Dockerfile}
  YAML

private def lint_args(dir : String, file : String) : Array(String)
  ["run", "--pull", "always", "--rm", "-e", "MISE_IGNORED_CONFIG_PATHS=/app/mise.toml", "--workdir", "/app",
   "-v", "#{dir}:/app", "tools/hadolint:1", "hadolint", file]
end

private def lint(env : Donico::Env, runner : RecordingRunner) : Int32
  Donico::Tasks::LintDockerfile.new(Donico::Config.load(env), env, runner, "tools/hadolint:1").run
end

describe Donico::Tasks::LintDockerfile do
  it "runs hadolint once on the Dockerfile and prints OK when it passes" do
    with_project(YAML_ONE) do |env|
      runner = RecordingRunner.new

      lint(env, runner).should eq 0

      runner.calls.size.should eq 1
      runner.calls[0].kind.should eq :capture
      runner.calls[0].command.should eq "docker"
      runner.calls[0].args.should eq lint_args(env.dir, "/app/Dockerfile")
      env.stdout.to_s.should eq "Dockerfile is OK!\n"
    end
  end

  it "returns 1 and prints the captured text when hadolint reports a violation" do
    with_project(YAML_ONE) do |env|
      runner = RecordingRunner.new.script(1, "DL3008 pin versions\n")

      lint(env, runner).should eq 1

      env.stdout.to_s.should eq "DL3008 pin versions\n"
    end
  end

  it "lints every distinct Dockerfile, all of them even when the first fails" do
    with_project(YAML_MANY) do |env|
      runner = RecordingRunner.new.script(1, "first failed\n").script(0, "")

      lint(env, runner).should eq 1

      runner.calls.map(&.args).should eq [
        lint_args(env.dir, "/app/dockerfiles/3.1/Dockerfile"),
        lint_args(env.dir, "/app/dockerfiles/3.2/Dockerfile"),
      ]
    end
  end

  it "prints the non-empty outputs joined by a newline, each as captured" do
    with_project(YAML_MANY) do |env|
      runner = RecordingRunner.new.script(1, "first failed\n").script(1, "second failed")

      lint(env, runner).should eq 1

      env.stdout.to_s.should eq "first failed\n\nsecond failed\n"
    end
  end

  it "skips the empty outputs of the runs that passed" do
    with_project(YAML_MANY) do |env|
      runner = RecordingRunner.new.script(0, "").script(1, "only this\n")

      lint(env, runner).should eq 1

      env.stdout.to_s.should eq "only this\n"
    end
  end

  it "prints a single empty line when it fails with nothing to show" do
    with_project(YAML_ONE) do |env|
      runner = RecordingRunner.new.script(1, "")

      lint(env, runner).should eq 1

      env.stdout.to_s.should eq "\n"
    end
  end
end
