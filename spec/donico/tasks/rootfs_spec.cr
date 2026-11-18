require "../../spec_helper"

private FIXTURES = File.join(__DIR__, "..", "..", "fixtures", "debuerreotype")

# Two rows: the first with two archs and nothing else, the second end-of-life.
private YAML_ROOTFS = <<-YAML
  registry: harbor.example.org/debian
  image_builder: debuerreotype
  matrix:
    - distro: trixie
      version: "13"
      archs: ["linux/amd64", "linux/arm64"]
    - distro: jessie
      version: "8"
      eol: true

  YAML

# What a debian-base repository holds besides donico.yml.
private SOURCES = {
  "config/apt/13-trixie.list" => "deb http://deb.debian.org/debian trixie main\n",
  "config/apt/8-jessie.list"  => "deb http://archive.debian.org/debian jessie main\n",
  "config/apt/apt-no-check"   => "Acquire::Check-Valid-Until \"false\";\n",
  "build/.gitkeep"            => "",
}

private IMAGE = "harbor.example.org/debian/debuerreotype:latest"

private def rootfs_for(env : Donico::Env, index : Int32 = 0) : Donico::Rootfs
  Donico::Rootfs.all(Donico::Config.load(env))[index]
end

# The arguments of the `docker run` of a build, with the project directory
# and the script left to the caller.
private def docker_run(dir : String, script : String) : Array(String)
  [
    "run", "--hostname", "debuerreotype", "--init", "--interactive", "--rm", "--pull", "always",
    "--cap-add", "SYS_ADMIN", "--cap-drop", "SETFCAP", "--security-opt", "apparmor=unconfined",
    "--tmpfs", "/tmp:dev,exec,suid,noatime", "--env", "TMPDIR=/tmp", "--workdir", "/workdir",
    "--mount", "type=bind,src=#{dir}/build,dst=/workdir",
    "--mount", "type=bind,src=#{dir}/config,dst=/config",
    IMAGE, "bash", "-euc", script,
  ]
end

private def run_with_recorder(env : Donico::Env, args : Array(String), runner : RecordingRunner) : CliRun
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  factory = ->(_env : Donico::Env) { runner.as(Donico::Runner) }
  code = Donico::CLI.new(stdout, stderr, env.dir, env.vars, env.now, factory).run(args)
  CliRun.new(code, stdout.to_s, stderr.to_s)
end

# A recording runner that delivers TERM to the build task while its container
# runs, as the signal handler would, then lets the container end normally.
private class InterruptingRunner < RecordingRunner
  property task : Donico::Tasks::RootfsBuild?

  def system(command : String, args : Array(String), env : Vars = Vars.new) : Int32
    code = super
    task.try(&.handle_signal(Signal::TERM))
    code
  end
end

private VALID_TASKS = <<-TEXT
  Valid tasks:
    generate-files
    help
    image-builder
    inspec
    jessie:8:build
    jessie:8:clean
    jessie:8:push
    licenses
    lint-dockerfile
    matrix
    trixie:13:build
    trixie:13:clean
    trixie:13:push
    version

  TEXT

describe Donico::Tasks::RootfsBuild do
  it "runs debuerreotype once per arch, in order, with the script of the arch" do
    with_project(YAML_ROOTFS, files: SOURCES) do |env|
      runner = RecordingRunner.new

      Donico::Tasks::RootfsBuild.new(rootfs_for(env), env, runner, IMAGE).run.should eq 0

      runner.calls.map(&.kind).should eq [:system, :system]
      runner.calls.map(&.command).should eq ["docker", "docker"]
      amd64 = File.read(File.join(FIXTURES, "trixie.sh")).chomp
      runner.calls[0].args.should eq docker_run(env.dir, amd64)
      runner.calls[1].args.should eq docker_run(env.dir, amd64.gsub("amd64", "arm64"))
      runner.calls.map(&.env).should eq [{} of String => String, {} of String => String]
      env.stdout.to_s.should eq "Building trixie for linux/amd64 (build/trixie-amd64-20260730.tar)\n" \
                                "Building trixie for linux/arm64 (build/trixie-arm64-20260730.tar)\n"
    end
  end

  it "stops at the first arch that fails, with its exit code" do
    with_project(YAML_ROOTFS, files: SOURCES) do |env|
      runner = RecordingRunner.new.script(3)

      Donico::Tasks::RootfsBuild.new(rootfs_for(env), env, runner, IMAGE).run.should eq 3

      runner.calls.size.should eq 1
    end
  end

  it "returns the code of the last arch when the first passed" do
    with_project(YAML_ROOTFS, files: SOURCES) do |env|
      runner = RecordingRunner.new.script(0).script(137)

      Donico::Tasks::RootfsBuild.new(rootfs_for(env), env, runner, IMAGE).run.should eq 137
    end
  end

  it "creates the build directory when the repository does not hold it" do
    with_project(YAML_ROOTFS, files: SOURCES.reject("build/.gitkeep")) do |env|
      Donico::Tasks::RootfsBuild.new(rootfs_for(env), env, RecordingRunner.new, IMAGE).run.should eq 0

      Dir.exists?(File.join(env.dir, "build")).should be_true
    end
  end

  it "names the APT sources file the row needs and starts nothing without it" do
    with_project(YAML_ROOTFS, files: SOURCES.reject("config/apt/13-trixie.list")) do |env|
      runner = RecordingRunner.new

      error = expect_raises(Donico::EnvironmentError) do
        Donico::Tasks::RootfsBuild.new(rootfs_for(env), env, runner, IMAGE).run
      end

      error.message.should eq "config/apt/13-trixie.list not found: the build copies it to etc/apt/sources.list"
      runner.calls.should be_empty
    end
  end

  it "names both files an end-of-life row needs" do
    with_project(YAML_ROOTFS) do |env|
      error = expect_raises(Donico::ProblemList) do
        Donico::Tasks::RootfsBuild.new(rootfs_for(env, 1), env, RecordingRunner.new, IMAGE).run
      end

      error.problems.should eq [
        "config/apt/8-jessie.list not found: the build copies it to etc/apt/sources.list",
        "config/apt/apt-no-check not found: the build of an eol row copies it to etc/apt/apt.conf.d/",
      ]
    end
  end

  # debuerreotype-init refuses a target directory that exists and is not
  # empty, after the image was pulled and the container started.
  it "names the build directories left by an earlier build, and starts nothing" do
    left = SOURCES.merge({"build/trixie-arm64-20260730/etc/os-release" => "", "build/trixie-amd64-20260729/etc/os-release" => ""})
    with_project(YAML_ROOTFS, files: left) do |env|
      runner = RecordingRunner.new

      error = expect_raises(Donico::EnvironmentError) do
        Donico::Tasks::RootfsBuild.new(rootfs_for(env), env, runner, IMAGE).run
      end

      error.message.should eq "build/trixie-arm64-20260730 already exists: run `donico trixie:13:clean` first"
      runner.calls.should be_empty
    end
  end

  it "builds over an empty build directory, as debuerreotype does" do
    with_project(YAML_ROOTFS, files: SOURCES) do |env|
      Dir.mkdir_p(File.join(env.dir, "build", "trixie-amd64-20260730"))

      Donico::Tasks::RootfsBuild.new(rootfs_for(env), env, RecordingRunner.new, IMAGE).run.should eq 0
    end
  end

  it "forwards an interrupt to the running container, stops there and returns 128 + the signal" do
    with_project(YAML_ROOTFS, files: SOURCES) do |env|
      runner = InterruptingRunner.new
      task = Donico::Tasks::RootfsBuild.new(rootfs_for(env), env, runner, IMAGE)
      runner.task = task

      task.run.should eq 128 + Signal::TERM.value

      runner.calls.map(&.kind).should eq [:system, :forward]
      runner.calls[1].command.should eq "TERM"
      task.interrupted?.should be_true
    end
  end

  it "is not interrupted by a signal of an earlier run" do
    with_project(YAML_ROOTFS, files: SOURCES) do |env|
      runner = InterruptingRunner.new
      task = Donico::Tasks::RootfsBuild.new(rootfs_for(env), env, runner, IMAGE)
      runner.task = task
      task.run

      runner.task = nil
      task.run.should eq 0
      task.interrupted?.should be_false
    end
  end

  it "does not ask a row that is not end-of-life for apt-no-check" do
    with_project(YAML_ROOTFS, files: SOURCES.reject("config/apt/apt-no-check")) do |env|
      Donico::Tasks::RootfsBuild.new(rootfs_for(env), env, RecordingRunner.new, IMAGE).run.should eq 0
    end
  end

  # `--mount` splits its value on commas.
  it "refuses a project directory with a comma in its path" do
    with_tmp_dir do |parent|
      dir = File.join(parent, "a,b")
      Dir.mkdir_p(File.join(dir, "config", "apt"))
      File.write(File.join(dir, "donico.yml"), YAML_ROOTFS)
      File.write(File.join(dir, "config", "apt", "13-trixie.list"), "")
      env = Donico::Env.new({} of String => String, dir, IO::Memory.new, IO::Memory.new, Time.utc(2026, 7, 31))
      runner = RecordingRunner.new

      error = expect_raises(Donico::EnvironmentError) do
        Donico::Tasks::RootfsBuild.new(rootfs_for(env), env, runner, IMAGE).run
      end

      error.message.should eq "#{dir} holds a comma, which docker cannot mount: move the project"
      runner.calls.should be_empty
    end
  end
end

describe Donico::Tasks::RootfsPush do
  tarballs = {"build/trixie-amd64-20260730.tar" => "", "build/trixie-arm64-20260730.tar" => ""}

  it "reads the Debian version from the tarball of the first arch, then replaces the process with buildx build" do
    with_project(YAML_ROOTFS, files: tarballs) do |env|
      runner = RecordingRunner.new.script(0, "13.2\n").script(5)

      Donico::Tasks::RootfsPush.new(rootfs_for(env), env, runner).run.should eq 5

      runner.calls.size.should eq 2
      read, push = runner.calls
      read.kind.should eq :output
      read.command.should eq "tar"
      read.args.should eq ["-O", "-xf", "build/trixie-amd64-20260730.tar", "etc/debian_version"]
      push.kind.should eq :exec
      push.command.should eq "docker"
      push.args.should eq [
        "buildx", "build", "--no-cache", "--platform", "linux/amd64,linux/arm64",
        "--build-arg", "DISTRO=trixie", "--build-arg", "BUILD_TIMESTAMP=20260730",
        "-t", "harbor.example.org/debian/trixie:latest",
        "-t", "harbor.example.org/debian/trixie:13",
        "-t", "harbor.example.org/debian/trixie:13.2",
        "-t", "harbor.example.org/debian/trixie:20260730",
        "-o", "type=registry", ".",
      ]
      push.env.should eq({} of String => String)
      env.stdout.to_s.should eq "Pushing Docker image: trixie (tags: latest/13/13.2/20260730)\n"
    end
  end

  it "names every missing tarball and the task that builds them, and calls nothing" do
    with_project(YAML_ROOTFS, files: {"build/trixie-arm64-20260729.tar" => ""}) do |env|
      runner = RecordingRunner.new

      error = expect_raises(Donico::ProblemList) { Donico::Tasks::RootfsPush.new(rootfs_for(env), env, runner).run }

      error.problems.should eq [
        "build/trixie-amd64-20260730.tar not found: run `donico trixie:13:build` first",
        "build/trixie-arm64-20260730.tar not found: run `donico trixie:13:build` first",
      ]
      runner.calls.should be_empty
    end
  end

  it "reports a tarball tar cannot read, and pushes nothing" do
    with_project(YAML_ROOTFS, files: tarballs) do |env|
      runner = RecordingRunner.new.script(2, "")

      error = expect_raises(Donico::EnvironmentError) { Donico::Tasks::RootfsPush.new(rootfs_for(env), env, runner).run }

      error.message.should eq "cannot read etc/debian_version from build/trixie-amd64-20260730.tar (tar exited with 2)"
      runner.calls.size.should eq 1
    end
  end

  # testing and unstable hold "trixie/sid": neither a tag nor a version.
  it "refuses a Debian version that is not a release number, and pushes nothing" do
    with_project(YAML_ROOTFS, files: tarballs) do |env|
      ["trixie/sid\n", "\n", "13.2 x\n", "13.\n"].each do |text|
        runner = RecordingRunner.new.script(0, text)

        error = expect_raises(Donico::EnvironmentError) { Donico::Tasks::RootfsPush.new(rootfs_for(env), env, runner).run }

        error.message.should eq %(etc/debian_version of build/trixie-amd64-20260730.tar holds "#{text.strip}", which is not a Debian release number)
        runner.calls.size.should eq 1
      end
    end
  end

  it "tags a version without a minor twice, as danico did" do
    with_project(YAML_ROOTFS, files: tarballs) do |env|
      runner = RecordingRunner.new.script(0, "13\n")

      Donico::Tasks::RootfsPush.new(rootfs_for(env), env, runner).run.should eq 0

      runner.calls[1].args.select(&.starts_with?("harbor")).should eq [
        "harbor.example.org/debian/trixie:latest",
        "harbor.example.org/debian/trixie:13",
        "harbor.example.org/debian/trixie:13",
        "harbor.example.org/debian/trixie:20260730",
      ]
    end
  end
end

describe Donico::Tasks::RootfsClean do
  leftovers = {
    "build/.gitkeep"                             => "",
    "build/trixie-amd64-20260730.tar"            => "",
    "build/trixie-amd64-20260730/etc/os-release" => "",
    "build/trixie-amd64-20260729.tar"            => "",
    "build/trixie-arm64-20260730.tar"            => "",
    "build/trixie-armhf-20260730.tar"            => "",
    "build/jessie-amd64-20260730.tar"            => "",
    "build/trixie-backports-amd64-20260730.tar"  => "",
  }

  it "removes what the archs of the row left in build/, through sudo, one arch at a time" do
    with_project(YAML_ROOTFS, files: leftovers) do |env|
      runner = RecordingRunner.new
      build = File.join(env.dir, "build")

      Donico::Tasks::RootfsClean.new(rootfs_for(env), env, runner, root: false).run.should eq 0

      runner.calls.map(&.kind).should eq [:system, :system]
      runner.calls.map(&.command).should eq ["sudo", "sudo"]
      runner.calls[0].args.should eq [
        "rm", "-rf", "#{build}/trixie-amd64-20260729.tar", "#{build}/trixie-amd64-20260730", "#{build}/trixie-amd64-20260730.tar",
      ]
      runner.calls[1].args.should eq ["rm", "-rf", "#{build}/trixie-arm64-20260730.tar"]
    end
  end

  it "calls rm itself when running as root" do
    with_project(YAML_ROOTFS, files: leftovers) do |env|
      runner = RecordingRunner.new
      build = File.join(env.dir, "build")

      Donico::Tasks::RootfsClean.new(rootfs_for(env, 1), env, runner, root: true).run.should eq 0

      runner.calls.size.should eq 1
      runner.calls[0].command.should eq "rm"
      runner.calls[0].args.should eq ["-rf", "#{build}/jessie-amd64-20260730.tar"]
    end
  end

  it "calls nothing when there is nothing to remove" do
    with_project(YAML_ROOTFS, files: {"build/.gitkeep" => ""}) do |env|
      runner = RecordingRunner.new

      Donico::Tasks::RootfsClean.new(rootfs_for(env), env, runner, root: false).run.should eq 0

      runner.calls.should be_empty
    end
  end

  it "calls nothing without a build directory" do
    with_project(YAML_ROOTFS) do |env|
      runner = RecordingRunner.new

      Donico::Tasks::RootfsClean.new(rootfs_for(env), env, runner, root: false).run.should eq 0

      runner.calls.should be_empty
    end
  end

  it "stops at the first removal that fails, with its exit code" do
    with_project(YAML_ROOTFS, files: leftovers) do |env|
      runner = RecordingRunner.new.script(1)

      Donico::Tasks::RootfsClean.new(rootfs_for(env), env, runner, root: false).run.should eq 1

      runner.calls.size.should eq 1
    end
  end
end

describe "Donico::CLI tasks of the debuerreotype backend" do
  it "dispatches <distro>:<version>:build with the debuerreotype image of the tools registry" do
    with_project(YAML_ROOTFS + "tools_registry: tools.example.org/ci\n", files: SOURCES) do |env|
      runner = RecordingRunner.new.script(0).script(9)

      run = run_with_recorder(env, ["trixie:13:build"], runner)

      run.code.should eq 9
      runner.calls.size.should eq 2
      runner.calls[0].args[-4].should eq "tools.example.org/ci/debuerreotype:latest"
    end
  end

  it "uses debuerreotype_image when the key is set" do
    with_project(YAML_ROOTFS + "debuerreotype_image: x.example.org/debuerreotype:0.17\n", files: SOURCES) do |env|
      runner = RecordingRunner.new

      run_with_recorder(env, ["jessie:8:build"], runner).code.should eq 0

      runner.calls.size.should eq 1
      runner.calls[0].args[-4].should eq "x.example.org/debuerreotype:0.17"
      runner.calls[0].args.last.should contain ";debuerreotype-gpgv-ignore-expiration-config jessie-amd64-20260730;"
    end
  end

  it "reads ENABLE_APT_PROXY from the .env of the project" do
    files = SOURCES.merge({".env" => "ENABLE_APT_PROXY=false\n"})
    with_project(YAML_ROOTFS + "apt_proxy: http://proxy.example.org:3142\n", files: files) do |env|
      runner = RecordingRunner.new

      run_with_recorder(env, ["trixie:13:build"], runner).code.should eq 0

      runner.calls[0].args.last.should eq File.read(File.join(FIXTURES, "trixie.sh")).chomp
    end
  end

  it "dispatches <distro>:<version>:push" do
    with_project(YAML_ROOTFS, files: {"build/jessie-amd64-20260730.tar" => ""}) do |env|
      runner = RecordingRunner.new.script(0, "8.11\n").script(4)

      run = run_with_recorder(env, ["jessie:8:push"], runner)

      run.code.should eq 4
      runner.calls[1].args.first(5).should eq ["buildx", "build", "--no-cache", "--platform", "linux/amd64"]
      runner.calls[1].args.should contain "harbor.example.org/debian/jessie:8.11"
    end
  end

  it "reports a missing tarball on one line" do
    with_project(YAML_ROOTFS) do |env|
      run = run_with_recorder(env, ["jessie:8:push"], RecordingRunner.new)

      run.code.should eq 1
      run.stderr.should eq "donico: build/jessie-amd64-20260730.tar not found: run `donico jessie:8:build` first\n"
    end
  end

  # Whether the spec runs as root decides between `rm` and `sudo rm`: only
  # what is removed is asserted here.
  it "dispatches <distro>:<version>:clean" do
    with_project(YAML_ROOTFS, files: {"build/jessie-amd64-20260730.tar" => ""}) do |env|
      runner = RecordingRunner.new

      run_with_recorder(env, ["jessie:8:clean"], runner).code.should eq 0

      runner.calls.size.should eq 1
      runner.calls[0].args.last(2).should eq ["-rf", File.join(env.dir, "build", "jessie-amd64-20260730.tar")]
    end
  end

  it "has neither test nor login" do
    with_project(YAML_ROOTFS) do |env|
      ["trixie:13:test", "trixie:13:login"].each do |task|
        runner = RecordingRunner.new
        run = run_with_recorder(env, [task], runner)

        run.code.should eq 1
        run.stderr.should eq "donico: unknown task: #{task}\n#{VALID_TASKS}"
        runner.calls.should be_empty
      end
    end
  end

  it "rejects a row that does not exist, listing the valid tasks" do
    with_project(YAML_ROOTFS) do |env|
      run = run_with_recorder(env, ["trixie:12:build"], RecordingRunner.new)

      run.code.should eq 1
      run.stderr.should eq "donico: unknown task: trixie:12:build\n#{VALID_TASKS}"
    end
  end
end
