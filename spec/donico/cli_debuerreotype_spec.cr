require "../spec_helper"

private YAML_ROOTFS = <<-YAML
  registry: harbor.example.org/debian
  image_builder: debuerreotype
  apt_proxy: http://proxy.example.org:3142
  matrix:
    - distro: trixie
      version: "13"
      archs: ["linux/amd64", "linux/arm64"]
    - distro: jessie
      version: "8"
      eol: true
      debootstrap_url: http://archive.debian.org/debian
      debootstrap_opts: []
      timestamp: "20261117"

  YAML

private HELP = <<-TEXT + "\n\n"
  Usage:

    donico generate-files   # Generate GitlabCI matrix
    donico image-builder    # Print the configured image builder
    donico inspec           # Run the Inspec harness on an image
    donico jessie:8:build   # Build root filesystem for jessie/8 ["linux/amd64"]
    donico jessie:8:clean   # Clean root filesystem for jessie/8 ["linux/amd64"]
    donico jessie:8:push    # Push docker image for jessie/8 ["linux/amd64"]
    donico licenses         # Print the third-party notices embedded in this binary
    donico lint-dockerfile  # Lint Dockerfile
    donico matrix           # Print the resolved matrix as JSON
    donico trixie:13:build  # Build root filesystem for trixie/13 ["linux/amd64", "linux/arm64"]
    donico trixie:13:clean  # Clean root filesystem for trixie/13 ["linux/amd64", "linux/arm64"]
    donico trixie:13:push   # Push docker image for trixie/13 ["linux/amd64", "linux/arm64"]
    donico version          # Version
  TEXT

private MATRIX_JSON = <<-JSON + "\n"
  [
    {
      "distro": "trixie",
      "version": "13",
      "archs": [
        "linux/amd64",
        "linux/arm64"
      ],
      "eol": false,
      "debootstrap_opts": [
        "--debian"
      ],
      "timestamp": "20260730",
      "image": "harbor.example.org/debian/trixie",
      "tarballs": [
        "build/trixie-amd64-20260730.tar",
        "build/trixie-arm64-20260730.tar"
      ]
    },
    {
      "distro": "jessie",
      "version": "8",
      "archs": [
        "linux/amd64"
      ],
      "eol": true,
      "debootstrap_opts": [],
      "timestamp": "20261117",
      "image": "harbor.example.org/debian/jessie",
      "tarballs": [
        "build/jessie-amd64-20261117.tar"
      ]
    }
  ]
  JSON

private MATRIX_FILE = <<-YAML + "\n"
  # !!! THIS IS A GENERATED FILE !!! DON'T EDIT ME MANUALLY !!!
  # Instead edit donico.yml and run donico generate-files
  ---
  ".matrix":
    parallel:
      matrix:
      - VERSION: '13'
        DOCKER_DISTRO: trixie
      - VERSION: '8'
        DOCKER_DISTRO: jessie
  YAML

# Runs the CLI on YAML_ROOTFS at the fixed clock of with_project, with no
# process variable.
private def run_rootfs(args : Array(String), & : CliRun, String ->) : Nil
  with_project(YAML_ROOTFS) do |env|
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    code = Donico::CLI.new(stdout, stderr, env.dir, env.vars, env.now).run(args)
    yield CliRun.new(code, stdout.to_s, stderr.to_s), env.dir
  end
end

describe "Donico::CLI with image_builder: debuerreotype" do
  it "prints debuerreotype for image-builder" do
    run_rootfs(["image-builder"]) do |run, _|
      run.code.should eq 0
      run.stdout.should eq "debuerreotype\n"
    end
  end

  it "lists three tasks per row in help, among the built-ins" do
    run_rootfs(["help"]) do |run, _|
      run.code.should eq 0
      run.stdout.should eq HELP
      run.stderr.should be_empty
    end
  end

  # Neither URL may be printed: a private mirror, like a proxy, is often
  # written with its credentials.
  it "prints neither the proxy nor the mirror for matrix" do
    yaml = YAML_ROOTFS.sub("http://archive.debian.org/debian", "http://user:secret@mirror.example.org/debian")
    with_project(yaml) do |env|
      run = run_cli_in(env.dir, ["matrix"])

      run.code.should eq 0
      run.stdout.should_not contain "secret"
      run.stdout.should_not contain "proxy.example.org"
    end
  end

  it "prints the rows as JSON for matrix, with what each row resolves to" do
    run_rootfs(["matrix"]) do |run, _|
      run.code.should eq 0
      run.stdout.should eq MATRIX_JSON
    end
  end

  it "writes the CI matrix alone for generate-files, and no bakefile" do
    run_rootfs(["generate-files"]) do |run, dir|
      run.code.should eq 0
      run.stdout.should eq "GitlabCI Matrix file generated\n"
      File.read(File.join(dir, ".gitlab-ci", "extends", ".matrix.yml")).should eq MATRIX_FILE
      Dir.children(dir).sort.should eq [".gitlab-ci", "donico.yml"]
      Dir.children(File.join(dir, ".gitlab-ci", "extends")).should eq [".matrix.yml"]
    end
  end

  it "leaves a bakefile that is already there untouched" do
    with_project(YAML_ROOTFS, files: {"docker-bake.hcl" => "mine\n"}) do |env|
      run_cli_in(env.dir, ["generate-files"]).code.should eq 0

      File.read(File.join(env.dir, "docker-bake.hcl")).should eq "mine\n"
    end
  end
end
