require "../../spec_helper"

private def manifest(extra : String = "") : String
  "registry:  harbor.example.org/base\ngroup:     git@example.org:factory/images\nworkspace: docker-images\nimages:\n  - traefik\n  - ruby\n  - donico:\n      bump_donico: false\n#{extra}"
end

private def donico_yml : String
  <<-YAML
    registry: harbor.example.org/base
    image_name: traefik
    github_repo: traefik/traefik
    matrix:
      - version: "3.7.9"
        distro: trixie
        tags:
          - "%<version>s-%<distro>s"

    YAML
end

private def mise_toml(pin : String) : String
  <<-TOML
    min_version = "2026.10.2"

    [tools]
    "aqua:jbox-web/donico" = "#{pin}"
    "aqua:elbywan/crystalline" = "0.18.0"

    TOML
end

# A fleet with traefik cloned and migrated to `pin`, plus whatever `files` adds.
private def with_pinned_fleet(pin : String = "0.0.1", files : Hash(String, String) = {} of String => String, & : Donico::Env, FakeGit ->) : Nil
  all = {
    "docker-images/traefik/donico.yml" => donico_yml,
    "docker-images/traefik/mise.toml"  => mise_toml(pin),
  }.merge(files)
  with_fleet(manifest, all) do |env|
    yield env, FakeGit.new
  end
end

private def pin(env : Donico::Env, git : FakeGit) : Donico::Fleet::DonicoPin
  Donico::Fleet::DonicoPin.new(fleet_repos_of(env), env, git.for_dir)
end

# The two backends the README proposes for the binary: the github one first.
private def github_mise_toml(pin : String) : String
  <<-TOML
    [tools]
    "github:jbox-web/donico" = "#{pin}"

    TOML
end

describe Donico::Fleet::DonicoPin do
  it "matches the pin line of mise.toml" do
    Donico::Fleet::DonicoPin::LINE.match(%(a = 1\n  "aqua:jbox-web/donico"   =  "3.0.0"\n))
      .try(&.[2]).should eq "3.0.0"
  end

  it "matches the pin line of the github backend too" do
    Donico::Fleet::DonicoPin::LINE.match(%(a = 1\n"github:jbox-web/donico" = "3.0.0"\n))
      .try(&.[2]).should eq "3.0.0"
  end

  it "does not take another tool of the same owner for the pin" do
    Donico::Fleet::DonicoPin::LINE.match(%("github:jbox-web/donico-extra" = "3.0.0"\n"ubi:jbox-web/donico" = "3.0.0"\n)).should be_nil
  end

  describe "a pin through the github backend" do
    it "is replaced, keeping its backend" do
      with_pinned_fleet(files: {"docker-images/traefik/mise.toml" => github_mise_toml("0.0.1")}) do |env, git|
        pin(env, git).call("traefik", "3.1.0").should eq({:ok, nil})
        File.read(File.join(env.dir, "docker-images/traefik/mise.toml")).should eq github_mise_toml("3.1.0")
      end
    end

    it "is replaced together with an aqua one when mise.toml holds both" do
      both = "[tools]\n\"aqua:jbox-web/donico\" = \"0.0.1\"\n\n[env]\nX = \"1\"\n\n[tools.other]\n\"github:jbox-web/donico\" = \"0.0.2\"\n"
      with_pinned_fleet(files: {"docker-images/traefik/mise.toml" => both}) do |env, git|
        pin(env, git).call("traefik", "3.1.0").should eq({:ok, nil})
        File.read(File.join(env.dir, "docker-images/traefik/mise.toml")).should eq both.sub("0.0.1", "3.1.0").sub("0.0.2", "3.1.0")
      end
    end
  end

  describe "the checks, in order" do
    it "skips an image the manifest excludes, before looking at the disk" do
      with_pinned_fleet do |env, git|
        pin(env, git).call("donico", "3.1.0").should eq({:skip, "donico: bump_donico is false"})
        git.calls.should be_empty
      end
    end

    it "skips an image that is not cloned" do
      with_pinned_fleet do |env, git|
        pin(env, git).call("ruby", "3.1.0").should eq({:skip, "ruby is not cloned"})
      end
    end

    it "skips an image without mise.toml, even when it is dirty" do
      with_pinned_fleet(files: {"docker-images/ruby/donico.yml" => donico_yml}) do |env, git|
        git.answer("status --porcelain", text: " M Dockerfile\n")

        pin(env, git).call("ruby", "3.1.0").should eq({:skip, "ruby: no donico pin in mise.toml"})
        git.calls.should be_empty
      end
    end

    it "skips an image whose mise.toml has no donico pin, even when it is dirty and off master" do
      with_pinned_fleet(files: {"docker-images/ruby/mise.toml" => "[tools]\ncrystal = \"1.20\"\n"}) do |env, git|
        git.answer("status --porcelain", text: " M Dockerfile\n").answer("rev-parse", text: "fix/x\n")

        pin(env, git).call("ruby", "3.1.0").should eq({:skip, "ruby: no donico pin in mise.toml"})
        git.calls.should be_empty
      end
    end

    it "fails on uncommitted changes, before the branch is looked at, and leaves mise.toml alone" do
      with_pinned_fleet do |env, git|
        git.answer("status --porcelain", text: " M Dockerfile\n").answer("rev-parse", text: "fix/x\n")

        pin(env, git).call("traefik", "3.1.0").should eq({:fail, "uncommitted changes in the repo"})
        git.lines("rev-parse").should be_empty
        File.read(File.join(env.dir, "docker-images/traefik/mise.toml")).should eq mise_toml("0.0.1")
      end
    end

    it "fails when git status fails, instead of reading it as clean" do
      with_pinned_fleet do |env, git|
        git.answer("status --porcelain", code: 128, text: "fatal: not a git repository\n")

        pin(env, git).call("traefik", "3.1.0").should eq({:fail, "git status failed: fatal: not a git repository"})
        File.read(File.join(env.dir, "docker-images/traefik/mise.toml")).should eq mise_toml("0.0.1")
      end
    end

    it "fails when the repository is not on master" do
      with_pinned_fleet do |env, git|
        git.answer("rev-parse", text: "fix/something\n")

        pin(env, git).call("traefik", "3.1.0").should eq({:fail, "on fix/something, not master"})
        File.read(File.join(env.dir, "docker-images/traefik/mise.toml")).should eq mise_toml("0.0.1")
      end
    end
  end

  describe "the pin" do
    it "is put back when the regeneration raises, and the exception goes through" do
      with_pinned_fleet do |env, git|
        path = File.join(env.dir, "docker-images/traefik/mise.toml")
        seen = nil.as(String?)
        exploding = ->(_env : Donico::Env, _dir : String) : Donico::Fleet::Outcome do
          seen = File.read(path)
          raise IO::Error.new("disk gone")
        end
        pin = Donico::Fleet::DonicoPin.new(fleet_repos_of(env), env, git.for_dir, exploding)

        expect_raises(IO::Error, "disk gone") { pin.call("traefik", "3.1.0") }
        seen.should eq mise_toml("3.1.0")
        File.read(path).should eq mise_toml("0.0.1")
      end
    end

    it "replaces the version and nothing else, then regenerates the files" do
      with_pinned_fleet do |env, git|
        pin(env, git).call("traefik", "3.1.0").should eq({:ok, nil})

        File.read(File.join(env.dir, "docker-images/traefik/mise.toml")).should eq mise_toml("3.1.0")
        File.exists?(File.join(env.dir, "docker-images/traefik/docker-bake.hcl")).should be_true
        File.exists?(File.join(env.dir, "docker-images/traefik/.gitlab-ci/extends/.matrix.yml")).should be_true
      end
    end

    it "does no git work beyond its two questions" do
      with_pinned_fleet do |env, git|
        pin(env, git).call("traefik", "3.1.0")

        git.lines.should eq ["git status --porcelain", "git rev-parse --abbrev-ref HEAD"]
        git.dirs.should eq [File.join(env.dir, "docker-images/traefik")]
      end
    end

    it "fails with the message of donico when its donico.yml is refused" do
      with_pinned_fleet(files: {"docker-images/traefik/donico.yml" => donico_yml.sub(%("3.7.9"), "3.10")}) do |env, git|
        status, message = pin(env, git).call("traefik", "3.1.0")

        status.should eq :fail
        message.to_s.should start_with("generate-files failed: donico.yml")
        File.read(File.join(env.dir, "docker-images/traefik/mise.toml")).should eq mise_toml("0.0.1")
      end
    end

    it "fails when the repository's .env cannot be read, without raising" do
      with_pinned_fleet(files: {"docker-images/traefik/.env" => "not a pair\n"}) do |env, git|
        status, message = pin(env, git).call("traefik", "3.1.0")

        status.should eq :fail
        message.to_s.should eq "generate-files failed: .env: line 1 is not KEY=VALUE"
        File.read(File.join(env.dir, "docker-images/traefik/mise.toml")).should eq mise_toml("0.0.1")
      end
    end
  end
end
