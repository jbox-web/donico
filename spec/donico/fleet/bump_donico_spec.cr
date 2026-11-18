require "../../spec_helper"

private VERSION = Donico::VERSION

private def donico_yml(version : String = "3.7.9") : String
  <<-YAML
    registry: harbor.example.org/base
    image_name: traefik
    github_repo: traefik/traefik
    matrix:
      - version: "#{version}"
        distro: trixie
        tags:
          - "%<version>s-%<distro>s"

    YAML
end

private def mise_toml(pin : String) : String
  "[tools]\n\"aqua:jbox-web/donico\" = \"#{pin}\"\n"
end

# Images sort as absent, donico (excluded), grafana, ruby, traefik. `absent`
# is not cloned; the others are, unless a spec says otherwise.
private def manifest : String
  <<-YAML
    registry:  harbor.example.org/base
    group:     git@example.org:factory/images
    workspace: docker-images
    images:
      - traefik
      - ruby
      - grafana
      - absent
      - donico:
          bump_donico: false

    YAML
end

private def migrated(name : String, pin : String = "0.0.1") : Hash(String, String)
  {"docker-images/#{name}/donico.yml" => donico_yml, "docker-images/#{name}/mise.toml" => mise_toml(pin)}
end

private def run_bump(env : Donico::Env, git : FakeGit, args : Array(String)) : CliRun
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  cli = Donico::Fleet::CLI.new(stdout, stderr, env.dir, {} of String => String, Time.utc(2026, 1, 1), git.factory)
  CliRun.new(cli.run(args), stdout.to_s, stderr.to_s)
end

describe "donico-manager bump-donico" do
  describe "the version argument" do
    it "refuses a version that is not made of numbers and dots, naming the binary's own" do
      with_fleet(manifest) do |env|
        ["x", "3.1.", "v3.1.0", ""].each do |bad|
          run = run_bump(env, FakeGit.new, ["bump-donico", bad])

          run.code.should eq 1
          run.stdout.should be_empty
          run.stderr.should eq "donico-manager: Expected a version like #{VERSION}, got #{bad}\n"
        end
      end
    end

    it "refuses a version that is not the one of the running binary" do
      with_fleet(manifest, migrated("traefik")) do |env|
        git = FakeGit.new
        run = run_bump(env, git, ["bump-donico", "0.0.1"])

        run.code.should eq 1
        run.stdout.should be_empty
        run.stderr.should eq "donico-manager: bump-donico 0.0.1: this binary is donico #{VERSION}, and the files it regenerates would be its own\n"
        git.calls.should be_empty
        File.read(File.join(env.dir, "docker-images/traefik/mise.toml")).should eq mise_toml("0.0.1")
      end
    end

    it "is required, and refuses an unknown option and a surplus argument" do
      with_fleet(manifest) do |env|
        run_bump(env, FakeGit.new, ["bump-donico"]).stderr.should eq "donico-manager: missing argument: VERSION\n"
        run_bump(env, FakeGit.new, ["bump-donico", "--push"]).stderr.should eq "donico-manager: missing argument: VERSION\n"
        run_bump(env, FakeGit.new, ["bump-donico", VERSION, "--nope"]).stderr.should eq "donico-manager: unknown option: --nope\n"
        run_bump(env, FakeGit.new, ["bump-donico", VERSION, "ruby"]).stderr.should eq "donico-manager: unexpected argument: ruby\n"
      end
    end
  end

  describe "a fleet in the middle of its switch" do
    it "reports each repository with the gem's lines and ends with status 0 when only skips and bumps happened" do
      files = migrated("traefik").merge({
        "docker-images/ruby/donico.yml"    => donico_yml,
        "docker-images/ruby/mise.toml"     => "[tools]\ncrystal = \"1.20\"\n",
        "docker-images/donico/donico.yml"  => donico_yml,
        "docker-images/donico/mise.toml"   => mise_toml("0.0.1"),
        "docker-images/grafana/donico.yml" => donico_yml,
      })
      with_fleet(manifest, files) do |env|
        git = FakeGit.new
        run = run_bump(env, git, ["bump-donico", VERSION])

        run.code.should eq 0
        run.stderr.should be_empty
        run.stdout.should eq [
          "  = absent is not cloned",
          "  = donico: bump_donico is false",
          "  = grafana: no donico pin in mise.toml",
          "  = ruby: no donico pin in mise.toml",
          "  + traefik",
          "",
          "Done.",
        ].join('\n') + "\n"
        File.read(File.join(env.dir, "docker-images/traefik/mise.toml")).should eq mise_toml(VERSION)
        File.read(File.join(env.dir, "docker-images/ruby/mise.toml")).should eq "[tools]\ncrystal = \"1.20\"\n"
        File.read(File.join(env.dir, "docker-images/donico/mise.toml")).should eq mise_toml("0.0.1")
        git.calls_in("ruby").should be_empty
        git.calls_in("grafana").should be_empty
      end
    end

    it "commits a bumped repository with the donico title and pushes nothing without --push" do
      with_fleet(manifest, migrated("traefik")) do |env|
        git = FakeGit.new
        run_bump(env, git, ["bump-donico", VERSION])

        git.lines("commit").size.should eq 1
        git.calls_in("traefik").find! { |call| call.args.first == "commit" }.args[2].should eq "build: bump to donico #{VERSION}"
        git.lines("push").should be_empty
      end
    end

    it "pushes each bumped repository with --push, and only those" do
      files = migrated("traefik").merge(migrated("ruby"))
      with_fleet(manifest, files) do |env|
        git = FakeGit.new
        run = run_bump(env, git, ["bump-donico", VERSION, "--push"])

        run.code.should eq 0
        git.calls.select { |call| call.line == "git push origin master" }.map(&.dir).should eq [
          File.join(env.dir, "docker-images/ruby"), File.join(env.dir, "docker-images/traefik"),
        ]
      end
    end

    it "accepts --push before the version" do
      with_fleet(manifest, migrated("traefik")) do |env|
        git = FakeGit.new
        run_bump(env, git, ["bump-donico", "--push", VERSION]).code.should eq 0
        git.lines("push").size.should eq 1
      end
    end
  end

  describe "failures" do
    it "fails a dirty repository, goes on with the others and ends with the count and status 1" do
      files = migrated("traefik").merge(migrated("ruby"))
      with_fleet(manifest, files) do |env|
        git = FakeGit.new.answer("status --porcelain", text: " M Dockerfile\n", repo: "ruby")
        run = run_bump(env, git, ["bump-donico", VERSION])

        run.code.should eq 1
        run.stdout.should eq [
          "  = absent is not cloned",
          "  = donico: bump_donico is false",
          "  = grafana is not cloned",
          "  ! ruby: uncommitted changes in the repo",
          "  + traefik",
          "",
          "1 repository/repositories failed.",
        ].join('\n') + "\n"
        File.read(File.join(env.dir, "docker-images/ruby/mise.toml")).should eq mise_toml("0.0.1")
        git.calls_in("ruby").map(&.line).should eq ["git status --porcelain"]
      end
    end

    it "fails a repository whose git status fails, not clean" do
      with_fleet(manifest, migrated("traefik")) do |env|
        git = FakeGit.new.answer("status --porcelain", code: 128, text: "fatal: not a git repository\n")
        run = run_bump(env, git, ["bump-donico", VERSION])

        run.code.should eq 1
        run.stdout.should contain("  ! traefik: git status failed: fatal: not a git repository\n")
        git.lines("commit").should be_empty
      end
    end

    it "fails a repository off master" do
      with_fleet(manifest, migrated("traefik")) do |env|
        git = FakeGit.new.answer("rev-parse", text: "fix/x\n")
        run = run_bump(env, git, ["bump-donico", VERSION])

        run.code.should eq 1
        run.stdout.should contain("  ! traefik: on fix/x, not master\n")
      end
    end

    # donico 3 refuses an unquoted 3.10: that repository fails with donico's
    # message and the others are bumped.
    it "fails a repository whose donico.yml donico refuses, with donico's message, and bumps the others" do
      files = migrated("traefik").merge(migrated("ruby")).merge({
        "docker-images/ruby/donico.yml" => donico_yml.sub(%("3.7.9"), "3.10"),
      })
      with_fleet(manifest, files) do |env|
        git = FakeGit.new
        run = run_bump(env, git, ["bump-donico", VERSION])

        run.code.should eq 1
        run.stdout.lines.find!(&.starts_with?("  ! ruby: ")).should start_with("  ! ruby: generate-files failed: donico.yml")
        run.stdout.should contain("  + traefik\n")
        run.stdout.lines.last.should eq "1 repository/repositories failed."
        git.calls_in("ruby").map(&.line).should eq ["git status --porcelain", "git rev-parse --abbrev-ref HEAD"]
        File.exists?(File.join(env.dir, "docker-images/traefik/docker-bake.hcl")).should be_true
        File.read(File.join(env.dir, "docker-images/ruby/mise.toml")).should eq mise_toml("0.0.1")
        File.read(File.join(env.dir, "docker-images/traefik/mise.toml")).should eq mise_toml(VERSION)
      end
    end

    it "reports a refused git add as a failed commit and does not push that repository" do
      with_fleet(manifest, migrated("traefik")) do |env|
        git = FakeGit.new.answer("add -A", code: 128, text: "fatal: Unable to create index.lock\n")
        run = run_bump(env, git, ["bump-donico", VERSION, "--push"])

        run.code.should eq 1
        run.stdout.should contain("  ! traefik: commit failed: fatal: Unable to create index.lock\n")
        run.stdout.lines.last.should eq "1 repository/repositories failed."
        git.lines("commit").should be_empty
        git.lines("push").should be_empty
      end
    end

    it "reports a refused commit as a failure and does not push that repository" do
      with_fleet(manifest, migrated("traefik")) do |env|
        git = FakeGit.new.answer("commit", code: 1, text: "hook declined\n")
        run = run_bump(env, git, ["bump-donico", VERSION, "--push"])

        run.code.should eq 1
        run.stdout.should eq [
          "  = absent is not cloned",
          "  = donico: bump_donico is false",
          "  = grafana is not cloned",
          "  = ruby is not cloned",
          "  + traefik",
          "  ! traefik: commit failed: hook declined",
          "",
          "1 repository/repositories failed.",
        ].join('\n') + "\n"
        git.lines("push").should be_empty
      end
    end

    # As in the gem, a push that fails is reported but is not a failure of the
    # repository: the commit is there, pushing can be retried.
    it "reports a refused push without changing the status" do
      with_fleet(manifest, migrated("traefik")) do |env|
        git = FakeGit.new.answer("push", code: 1, text: "rejected: non-fast-forward\n")
        run = run_bump(env, git, ["bump-donico", VERSION, "--push"])

        run.code.should eq 0
        run.stdout.should contain("  ! traefik: push failed: rejected: non-fast-forward\n")
        run.stdout.lines.last.should eq "Done."
      end
    end

    it "does not count a bump with nothing to commit, and still pushes when asked" do
      with_fleet(manifest, migrated("traefik")) do |env|
        git = FakeGit.new.answer("diff --cached", code: 0)
        run = run_bump(env, git, ["bump-donico", VERSION, "--push"])

        run.code.should eq 0
        git.lines("commit").should be_empty
        git.lines("push").size.should eq 1
      end
    end
  end
end
