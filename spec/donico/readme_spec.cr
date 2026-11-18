require "../spec_helper"
require "json"

# The README is user documentation, and an example nobody loads rots. A fenced
# block is checked when the line right before its opening fence is one of these
# HTML comments, which do not show in the rendered page:
#
#   <!-- donico.yml -->   a complete donico.yml, loaded through Config.load
#   <!-- .env -->         a complete .env, parsed by Dotenv.parse
#   <!-- matrix.json -->  the output of `donico matrix` for the first donico.yml
#   <!-- help -->         the output of `donico help` for the first donico.yml
#   <!-- .matrix.yml -->  the file `generate-files` writes for the first donico.yml
#   <!-- docker-bake.hcl --> the file `generate-files` writes for the first donico.yml
#
# The section on the debuerreotype backend has its own example, and its own
# markers for what the binary gives for it, on 2026-11-18:
#
#   <!-- donico.yml debuerreotype -->   the donico.yml of that section
#   <!-- help debuerreotype -->         the output of `donico help`
#   <!-- .matrix.yml debuerreotype -->  the file `generate-files` writes
#   <!-- matrix.json debuerreotype -->  the output of `donico matrix`
#   <!-- script debuerreotype -->       the build script of trixie on amd64,
#                                       one command per line
#
# A block without a marker is a fragment or a shell session and is not loaded.
private README_PATH = File.join(__DIR__, "..", "..", "README.md")

# `marker` => the bodies of the fenced blocks it precedes.
private def readme_blocks(marker : String) : Array(String)
  blocks = [] of String
  lines = File.read(README_PATH).lines
  lines.each_with_index do |line, index|
    next unless line.strip == "<!-- #{marker} -->"
    fence = lines[index + 1]?
    next unless fence && fence.starts_with?("```")
    body = [] of String
    lines[(index + 2)..].each do |text|
      break if text.starts_with?("```")
      body << text
    end
    blocks << body.join('\n') + "\n"
  end
  blocks
end

# The quick start runs at this instant: the timestamp is in the README text.
private QUICK_START_VARS = {"CI_COMMIT_TIMESTAMP" => "2026-11-17T09:30:00+01:00"}

# Runs the CLI on the README's first donico.yml and yields what it printed and
# the project directory it wrote to.
private def with_quick_start(args : Array(String), & : String, String ->) : Nil
  with_project(readme_blocks("donico.yml").first, vars: QUICK_START_VARS) do |env|
    stdout = IO::Memory.new
    code = Donico::CLI.new(stdout, IO::Memory.new, env.dir, QUICK_START_VARS).run(args)
    code.should eq(0)
    yield stdout.to_s, env.dir
  end
end

# One check per `<!-- donico.yml -->` example, in README order, on the value
# the prose around the block announces. A new example without a check here
# fails the count below instead of going unchecked.
private YAML_CHECKS = [
  # Quick start: two tags, one of them the macro form, on two platforms.
  ->(config : Donico::Config) do
    config.matrix.first.tags.should eq(["%<version>s-%<distro>s", "latest"])
    config.matrix.first.archs.should eq(["linux/amd64", "linux/arm64"])
  end,
  # Anchors and the merge key: two rows share the common part.
  ->(config : Donico::Config) do
    config.matrix.map(&.distro).should eq(["bookworm", "trixie"])
    config.matrix.map(&.build_args).should eq([["APP_USER=app"], ["APP_USER=app"]])
    config.matrix.map(&.archs).uniq!.should eq([["linux/amd64", "linux/arm64"]])
  end,
  # tools_registry: both tool images live under it.
  ->(config : Donico::Config) do
    tools = Donico::ToolImages.from(config)
    tools.docker_linter.should eq("registry.example.com/tools/hadolint:latest")
    tools.inspec.should eq("registry.example.com/tools/inspec:latest")
  end,
  # Explicit tool images win.
  ->(config : Donico::Config) do
    tools = Donico::ToolImages.from(config)
    tools.docker_linter.should eq("registry.example.com/ci/hadolint:2.12")
    tools.inspec.should eq("registry.example.com/ci/inspec:6")
  end,
  # test_variants: two variants.
  ->(config : Donico::Config) do
    config.matrix.first.test_variants.should eq([["run_mode=default"], ["run_mode=dind"]])
  end,
  # login_env: the two names, in order.
  ->(config : Donico::Config) do
    config.matrix.first.login_env.should eq(["SSH_PRIVATE_KEY", "HOST_KEYSCAN"])
  end,
  # Secrets: one variable, two files.
  ->(config : Donico::Config) do
    entry = config.matrix.first
    entry.secret_envs.map { |secret| secret["id"] }.should eq(["GITHUB_TOKEN"])
    entry.secret_files.map { |secret| {secret["id"], secret["src"]} }.should eq([{"aws", "${HOME}/.aws/credentials"}, {"netrc", ".netrc"}])
  end,
]

# The day the debuerreotype section was written: its timestamps are the day
# before.
private ROOTFS_NOW = Time.utc(2026, 11, 18, 10, 0, 0)

# Runs the CLI on the README's debuerreotype donico.yml and yields what it
# printed and the project directory it wrote to.
private def with_rootfs_example(args : Array(String), & : String, String ->) : Nil
  with_project(readme_blocks("donico.yml debuerreotype").first, now: ROOTFS_NOW) do |env|
    stdout = IO::Memory.new
    code = Donico::CLI.new(stdout, IO::Memory.new, env.dir, env.vars, env.now).run(args)
    code.should eq(0)
    yield stdout.to_s, env.dir
  end
end

describe "README.md" do
  describe "the debuerreotype example" do
    it "is the one donico.yml of its section, with the values its text announces" do
      blocks = readme_blocks("donico.yml debuerreotype")
      blocks.size.should eq(1)

      with_project(blocks.first, now: ROOTFS_NOW) do |env|
        config = Donico::Config.load(env)
        config.image_builder.should eq("debuerreotype")
        config.matrix.map { |row| {row.distro, row.version} }.should eq([{"trixie", "13"}, {"bookworm", "12"}])
        config.build_proxy.should eq("http://apt-proxy.example.com:3142")
        Donico::ToolImages.from(config).debuerreotype.should eq("registry.example.com/tools/debuerreotype:latest")
        Donico::Rootfs.all(config).first.tags("13.2").should eq([
          "registry.example.com/debian/trixie:latest",
          "registry.example.com/debian/trixie:13",
          "registry.example.com/debian/trixie:13.2",
          "registry.example.com/debian/trixie:20261117",
        ])
      end
    end

    it "lists what `donico help` prints" do
      with_rootfs_example(["help"]) do |stdout, _|
        stdout.rstrip.should eq(readme_blocks("help debuerreotype").first.rstrip)
      end
    end

    it "shows what `donico generate-files` writes" do
      with_rootfs_example(["generate-files"]) do |_, dir|
        File.read(File.join(dir, ".gitlab-ci", "extends", ".matrix.yml")).rstrip.should eq(readme_blocks(".matrix.yml debuerreotype").first.rstrip)
      end
    end

    it "shows what `donico matrix` prints" do
      with_rootfs_example(["matrix"]) do |stdout, _|
        JSON.parse(stdout).should eq(JSON.parse(readme_blocks("matrix.json debuerreotype").first))
      end
    end

    it "shows the build script of trixie on amd64, one command per line" do
      with_project(readme_blocks("donico.yml debuerreotype").first, now: ROOTFS_NOW) do |env|
        script = Donico::Rootfs.all(Donico::Config.load(env)).first.script("amd64")
        readme_blocks("script debuerreotype").first.rstrip.should eq(script.split(';').join('\n'))
      end
    end
  end

  describe "donico.yml examples" do
    blocks = readme_blocks("donico.yml")

    it "has exactly one check per example" do
      blocks.size.should eq(YAML_CHECKS.size)
    end

    blocks.each_with_index do |yaml, index|
      it "loads example #{index + 1} through Config.load, with the values its text announces" do
        with_project(yaml) do |env|
          config = Donico::Config.load(env)
          config.matrix.should_not be_empty
          config.image_builder.should eq("bake")
          YAML_CHECKS[index].call(config)
        end
      end
    end
  end

  describe ".env examples" do
    blocks = readme_blocks(".env")

    it "has an example to check" do
      blocks.size.should eq(1)
    end

    it "parses to the values the text describes" do
      Donico::Dotenv.parse(blocks.first).should eq({
        "HOST_KEYSCAN"    => "github.com ssh-rsa AAAA",
        "SSH_PRIVATE_KEY" => "line one # not a comment",
        "REGISTRY_USER"   => "bob",
        "TOKEN"           => "a=b=c",
        "EMPTY"           => "",
      })
    end
  end

  describe "the quick start output" do
    it "is what `donico matrix` prints" do
      with_quick_start(["matrix"]) do |stdout, _|
        JSON.parse(stdout).should eq(JSON.parse(readme_blocks("matrix.json").first))
      end
    end

    it "is what `donico help` prints" do
      with_quick_start(["help"]) do |stdout, _|
        stdout.rstrip.should eq(readme_blocks("help").first.rstrip)
      end
    end

    it "is what `donico generate-files` writes" do
      with_quick_start(["generate-files"]) do |_, dir|
        File.read(File.join(dir, ".gitlab-ci", "extends", ".matrix.yml")).rstrip.should eq(readme_blocks(".matrix.yml").first.rstrip)
        File.read(File.join(dir, "docker-bake.hcl")).rstrip.should eq(readme_blocks("docker-bake.hcl").first.rstrip)
      end
    end
  end
end
