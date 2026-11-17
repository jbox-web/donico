require "../../spec_helper"

private YAML_PLAIN = "registry: r\nimage_name: foo\nmatrix:\n  - version: \"1.0\"\n    distro: d\n"

private YAML_VARIANTS = YAML_PLAIN + "    test_variants:\n      - [\"run_mode=default\"]\n      - [\"run_mode=dind\", \"extra=1\"]\n"

private def image_for(env : Donico::Env) : Donico::Image
  Donico::Image.all(Donico::Config.load(env)).first
end

# The inputs a row of the fixtures gets from donico itself, with the fixed
# clock of with_project.
private BASE_INPUTS = ["build_date=20260731", "distro_name=d", "foo_version=1.0"]

describe Donico::Tasks::Test do
  it "runs the harness once on the build tag with the inputs of the row when there are no variants" do
    with_project(YAML_PLAIN) do |env|
      runner = RecordingRunner.new.script(0, "id").script(5)

      code = Donico::Tasks::Test.new(image_for(env), env, runner, "tools/inspec:1").run

      code.should eq 5
      runner.calls.size.should eq 3
      # The clock of `with_project` is fixed at 2026-07-31.
      runner.calls[0].args[3].should eq "foo/1.0/d:20260731"
      runner.calls[1].args.should contain "tools/inspec:1"
      runner.calls[1].args.last(4).should eq ["--input"] + BASE_INPUTS
    end
  end

  it "logs the run_cmd and with_exit_status lines of a full run through Runner::Real" do
    with_project(YAML_PLAIN, files: {"fake/docker" => "#!/bin/sh\ncase \"$1 $2 $3\" in\n  \"run --rm -d\") echo cid9 ;;\nesac\n"}) do |project|
      File.chmod(File.join(project.dir, "fake", "docker"), 0o755)
      env = Donico::Env.new({"PATH" => "#{project.dir}/fake:/usr/bin:/bin"}, project.dir, project.stdout, project.stderr, project.now)

      code = Donico::Tasks::Test.new(image_for(env), env, Donico::Runner::Real.new(env), "tools/inspec:1").run

      code.should eq 0
      logged = env.stdout.to_s.lines.select { |line| line.matches?(/\A(run_cmd:|with_exit_status:|Cleanup)/) }
      logged.should eq [
        "run_cmd: docker run --rm -d foo/1.0/d:20260731 /bin/bash -c while true; do sleep 1; done",
        "with_exit_status: docker run --rm --mount type=bind,source=#{env.dir},target=/app " \
        "--mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock tools/inspec:1 " \
        "inspec exec /app/test/ -t docker://cid9 --chef-license accept-silent --no-create-lockfile " \
        "--show-progress --input #{BASE_INPUTS.join(' ')}",
        "Cleanup docker containers",
        "with_exit_status: docker kill cid9",
      ]
    end
  end

  it "runs once per variant, the variant appended to the inputs, both even when the first fails" do
    with_project(YAML_VARIANTS) do |env|
      runner = RecordingRunner.new
      runner.script(0, "id1").script(3).script(0)
      runner.script(0, "id2").script(0).script(0)

      code = Donico::Tasks::Test.new(image_for(env), env, runner, "tools/inspec:1").run

      code.should eq 1
      runs = runner.calls.select(&.args.includes?("inspec"))
      runs.size.should eq 2
      runs[0].args.last(5).should eq ["--input"] + BASE_INPUTS + ["run_mode=default"]
      runs[1].args.last(6).should eq ["--input"] + BASE_INPUTS + ["run_mode=dind", "extra=1"]
      runs[1].env["run_mode"].should eq "dind"
    end
  end

  it "returns 0 when every variant passes" do
    with_project(YAML_VARIANTS) do |env|
      runner = RecordingRunner.new
      Donico::Tasks::Test.new(image_for(env), env, runner, "t").run.should eq 0
      runner.calls.count(&.args.includes?("inspec")).should eq 2
    end
  end

  it "stops at the first interrupted variant: one Inspec call, one cleanup, the signal code" do
    with_project(YAML_VARIANTS) do |env|
      runner = SignallingRunner.new.script(0, "id1").script(0)
      task = Donico::Tasks::Test.new(image_for(env), env, runner, "t")
      runner.harness = task.inspec

      task.run.should eq 130

      runner.calls.count(&.args.includes?("inspec")).should eq 1
      runner.calls.count { |call| call.args.first? == "kill" }.should eq 1
      runner.calls.count { |call| call.args.first? == "run" && call.args.includes?("-d") }.should eq 1
    end
  end
end
