require "../../../spec_helper"

private def manifest : String
  "registry:  harbor.example.org/base\ngroup:     git@example.org:factory/images\nworkspace: docker-images\nimages:\n  - traefik\n  - ruby\n"
end

private def donico_yml(version : String = "3.7.8", quote : String = "") : String
  <<-YAML
    ---
    registry: harbor.example.org/base
    image_name: traefik
    github_repo: traefik/traefik
    matrix:
      - version: #{quote}#{version}#{quote}
        distro: trixie
        tags:
          # keep the latest alias
          - "latest-%<distro>s"
          - "%<version>s-%<distro>s"

    YAML
end

private def mise(pin : String) : String
  "[tools]\n\"aqua:jbox-web/donico\" = \"#{pin}\"\n"
end

private def row(current : String = "3.7.8", latest : String? = "3.7.9", quoted : Bool = false, image : String = "traefik") : Donico::Fleet::Versions::Row
  Donico::Fleet::Versions::Row.new(image: image, current: current, latest: latest,
    state: Donico::Fleet::Versions::State::Update, repo: "traefik/traefik", quoted: quoted)
end

private def with_traefik(body : String = donico_yml, files : Hash(String, String) = {} of String => String, & : Donico::Env, FakeGit ->) : Nil
  with_fleet(manifest, {"docker-images/traefik/donico.yml" => body}.merge(files)) do |env|
    yield env, FakeGit.new
  end
end

private def bump(env : Donico::Env, git : FakeGit, row : Donico::Fleet::Versions::Row) : Donico::Fleet::Outcome
  Donico::Fleet::Versions::Bumper.new(fleet_repos_of(env), env, git.for_dir).call(row)
end

private def donico_of(env : Donico::Env) : String
  File.read(File.join(env.dir, "docker-images/traefik/donico.yml"))
end

describe Donico::Fleet::Versions::Bumper do
  describe "editing donico.yml" do
    it "rewrites the version, leaves the rest of the file untouched and regenerates the files" do
      with_traefik do |env, git|
        bump(env, git, row).should eq({:ok, nil})

        donico_of(env).should eq donico_yml("3.7.9")
        File.exists?(File.join(env.dir, "docker-images/traefik/docker-bake.hcl")).should be_true
        File.exists?(File.join(env.dir, "docker-images/traefik/.gitlab-ci/extends/.matrix.yml")).should be_true
      end
    end

    # An unquoted 4.40 is re-read by YAML as the float 4.4: the quoting style
    # must survive the rewrite.
    it "keeps the quotes when the scalar is quoted" do
      with_traefik(donico_yml("4.39", "\"")) do |env, git|
        bump(env, git, row(current: "4.39", latest: "4.40", quoted: true)).should eq({:ok, nil})

        donico_of(env).should eq donico_yml("4.40", "\"")
      end
    end

    it "keeps single quotes" do
      with_traefik(donico_yml("4.39", "'")) do |env, git|
        bump(env, git, row(current: "4.39", latest: "4.40", quoted: true)).should eq({:ok, nil})

        donico_of(env).should eq donico_yml("4.40", "'")
      end
    end

    it "rewrites only the first version line" do
      body = donico_yml + "  - version: 3.7.8\n    distro: bookworm\n"
      with_traefik(body) do |env, git|
        bump(env, git, row)

        donico_of(env).scan(/- version: (\S+)/).map(&.[1]).should eq ["3.7.9", "3.7.8"]
      end
    end
  end

  describe "regenerating the derived files" do
    it "fails with the message of donico when its donico.yml is refused" do
      with_traefik(donico_yml("3.10")) do |env, git|
        status, message = bump(env, git, row(current: "3.10", latest: "3.11"))

        status.should eq :fail
        message.to_s.should start_with("generate-files failed: donico.yml")
        donico_of(env).should eq donico_yml("3.10")
      end
    end

    it "fails when the .env of the repository is not valid, without raising" do
      with_traefik(files: {"docker-images/traefik/.env" => "oops\n"}) do |env, git|
        bump(env, git, row).should eq({:fail, "generate-files failed: .env: line 1 is not KEY=VALUE"})
        donico_of(env).should eq donico_yml
      end
    end
  end

  describe "a regeneration that raises" do
    it "puts donico.yml back, then lets the exception through" do
      with_traefik do |env, git|
        seen = nil.as(String?)
        exploding = ->(_env : Donico::Env, _dir : String) : Donico::Fleet::Outcome do
          seen = donico_of(env)
          raise IO::Error.new("disk gone")
        end
        bumper = Donico::Fleet::Versions::Bumper.new(fleet_repos_of(env), env, git.for_dir, exploding)

        expect_raises(IO::Error, "disk gone") { bumper.call(row) }
        seen.should eq donico_yml("3.7.9")
        donico_of(env).should eq donico_yml
      end
    end
  end

  describe "refusing an unfit repository" do
    it "fails when the repository is not cloned" do
      with_traefik do |env, git|
        bump(env, git, row(image: "ruby")).should eq({:fail, "ruby is not cloned (run `donico-manager repos clone`)"})
        git.calls.should be_empty
      end
    end

    it "fails when the repository has no donico.yml" do
      with_fleet(manifest, {"docker-images/traefik/Dockerfile" => "FROM scratch\n"}) do |env|
        git = FakeGit.new

        bump(env, git, row).should eq({:fail, "traefik has no donico.yml"})
      end
    end

    # The bumper finds the file through `ImageConfig.path`, as the README
    # generators do: a directory of that name is no configuration file.
    it "fails when donico.yml is a directory" do
      with_fleet(manifest, {"docker-images/traefik/donico.yml/keep" => ""}) do |env|
        git = FakeGit.new

        bump(env, git, row).should eq({:fail, "traefik has no donico.yml"})
      end
    end

    it "fails on uncommitted changes and leaves donico.yml alone" do
      with_traefik do |env, git|
        git.answer("status --porcelain", text: " M Dockerfile\n")

        bump(env, git, row).should eq({:fail, "uncommitted changes in the repo"})
        donico_of(env).should eq donico_yml
      end
    end

    it "fails when git status fails, instead of reading it as clean" do
      with_traefik do |env, git|
        git.answer("status --porcelain", code: 128, text: "fatal: not a git repository\n")

        bump(env, git, row).should eq({:fail, "git status failed: fatal: not a git repository"})
        donico_of(env).should eq donico_yml
      end
    end

    it "fails when the repository is not on master" do
      with_traefik do |env, git|
        git.answer("rev-parse", text: "fix/something\n")

        bump(env, git, row).should eq({:fail, "on fix/something, not master"})
        donico_of(env).should eq donico_yml
      end
    end

    it "asks git in the repository, status first" do
      with_traefik do |env, git|
        bump(env, git, row)

        git.lines.should eq ["git status --porcelain", "git rev-parse --abbrev-ref HEAD"]
        git.dirs.should eq [File.join(env.dir, "docker-images/traefik")]
      end
    end
  end

  describe "guarding against a stale version" do
    it "fails when donico.yml no longer holds the version the scan saw" do
      with_traefik do |env, git|
        bump(env, git, row(current: "3.7.0")).should eq({:fail, "donico.yml is no longer at 3.7.0 (found 3.7.8)"})
        donico_of(env).should eq donico_yml
      end
    end

    it "says it found nothing when no version line is left" do
      with_traefik("registry: x\n") do |env, git|
        bump(env, git, row).should eq({:fail, "donico.yml is no longer at 3.7.8 (found nothing)"})
      end
    end

    it "fails when the scan found no upstream version to move to" do
      with_traefik do |env, git|
        bump(env, git, row(latest: nil)).should eq({:fail, "traefik has no upstream version to bump to"})
        donico_of(env).should eq donico_yml
      end
    end
  end

  # The files donico regenerates are those of the running binary: a repository
  # pinned to another donico would get another donico's output.
  describe "the donico pin of mise.toml" do
    it "fails when the pin is not the version of this binary, and leaves donico.yml alone" do
      with_traefik(files: {"docker-images/traefik/mise.toml" => mise("0.0.1")}) do |env, git|
        bump(env, git, row).should eq({:fail, "pinned to donico 0.0.1, this binary is #{Donico::VERSION}"})
        donico_of(env).should eq donico_yml
      end
    end

    it "reads a pin through the github backend the same way" do
      github = "[tools]\n\"github:jbox-web/donico\" = \"0.0.1\"\n"
      with_traefik(files: {"docker-images/traefik/mise.toml" => github}) do |env, git|
        bump(env, git, row).should eq({:fail, "pinned to donico 0.0.1, this binary is #{Donico::VERSION}"})
        donico_of(env).should eq donico_yml
      end
    end

    it "fails when any of two pins is not the version of this binary" do
      both = "[tools]\n\"aqua:jbox-web/donico\" = \"#{Donico::VERSION}\"\n\"github:jbox-web/donico\" = \"0.0.1\"\n"
      with_traefik(files: {"docker-images/traefik/mise.toml" => both}) do |env, git|
        bump(env, git, row).should eq({:fail, "pinned to donico 0.0.1, this binary is #{Donico::VERSION}"})
        donico_of(env).should eq donico_yml
      end
    end

    it "bumps a repository pinned to this binary's version" do
      with_traefik(files: {"docker-images/traefik/mise.toml" => mise(Donico::VERSION)}) do |env, git|
        bump(env, git, row).should eq({:ok, nil})
        donico_of(env).should eq donico_yml("3.7.9")
      end
    end

    it "bumps a repository without a pin, and one without mise.toml" do
      with_traefik(files: {"docker-images/traefik/mise.toml" => "[tools]\ncrystal = \"1.20\"\n"}) do |env, git|
        bump(env, git, row).should eq({:ok, nil})
      end
      with_traefik do |env, git|
        bump(env, git, row).should eq({:ok, nil})
      end
    end
  end
end
