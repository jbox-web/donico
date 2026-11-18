require "../../../spec_helper"

private def manifest : String
  "registry:  harbor.example.org/base\ngroup:     git@example.org:factory/images\nworkspace: docker-images\nimages:\n  - traefik\n  - grafana\n"
end

private def row(image : String = "traefik", latest : String = "3.7.9") : Donico::Fleet::Versions::Row
  Donico::Fleet::Versions::Row.new(image: image, current: "3.7.8", latest: latest,
    state: Donico::Fleet::Versions::State::Update, repo: "traefik/traefik", quoted: false)
end

private def with_committer(& : Donico::Fleet::Versions::Committer, FakeGit, Donico::Env ->) : Nil
  with_fleet(manifest) do |env|
    git = FakeGit.new
    yield Donico::Fleet::Versions::Committer.new(fleet_repos_of(env), env, git.for_dir), git, env
  end
end

# The `-m` arguments of the one `git commit` of the run: {title, body}. The
# commit names `paths` after `--` when it is given any.
private def message(git : FakeGit, paths : Array(String) = [] of String) : {String, String}
  call = git.calls.find! { |candidate| candidate.command == "git" && candidate.args.first == "commit" }
  pathspec = paths.empty? ? [] of String : ["--"] + paths
  call.args.should eq ["commit", "-m", call.args[2], "-m", call.args[4]] + pathspec
  {call.args[2], call.args[4]}
end

# What `git diff --cached --quiet` answers when nothing is staged.
private def nothing_staged(git : FakeGit) : FakeGit
  git.answer("diff --cached", code: 0)
end

describe Donico::Fleet::Versions::Committer do
  describe "#commit_image" do
    it "stages everything and commits with the bump title and the gem's body" do
      with_committer do |committer, git, env|
        committer.commit_image(row).should eq({:ok, nil})

        git.lines.size.should eq 3
        git.lines.first(2).should eq ["git add -A", "git diff --cached --quiet"]
        git.calls.last.args.first.should eq "commit"
        message(git).should eq({"build: bump to 3.7.9", [
          "- donico.yml: new version",
          "- docker-bake.hcl: regenerated",
          "- .gitlab-ci/extends/.matrix.yml: regenerated",
          "- README.md: regenerated tags",
        ].join('\n')})
        git.dirs.should eq [File.join(env.dir, "docker-images/traefik")]
      end
    end

    # A bump that changed nothing must not create an empty commit.
    it "skips when nothing is staged" do
      with_committer do |committer, git|
        nothing_staged(git)

        committer.commit_image(row).should eq({:skip, nil})
        git.lines("commit").should be_empty
      end
    end

    it "reports a refused commit with git's message" do
      with_committer do |committer, git|
        git.answer("commit", code: 1, text: "hook declined\n")

        committer.commit_image(row).should eq({:fail, "hook declined"})
      end
    end
  end

  describe "a refused git add" do
    it "fails the commit with git's message, whichever commit asked, and goes no further" do
      {
        "commit_image"  => ->(c : Donico::Fleet::Versions::Committer) { c.commit_image(row) },
        "commit_donico" => ->(c : Donico::Fleet::Versions::Committer) { c.commit_donico("traefik", "1.15.0") },
        "commit_config" => ->(c : Donico::Fleet::Versions::Committer) { c.commit_config([row]) },
      }.each do |name, action|
        with_committer do |committer, git|
          git.answer("add", code: 128, text: "fatal: Unable to create index.lock\n")

          {name, action.call(committer)}.should eq({name, {:fail, "fatal: Unable to create index.lock"}})
          git.lines.size.should eq 1
        end
      end
    end
  end

  describe "#commit_donico" do
    it "commits with a build title naming the donico version and the body naming mise.toml" do
      with_committer do |committer, git, env|
        committer.commit_donico("traefik", "1.15.0").should eq({:ok, nil})

        git.lines.first(2).should eq ["git add -A", "git diff --cached --quiet"]
        message(git).should eq({"build: bump to donico 1.15.0", [
          "- mise.toml: new donico version",
          "- docker-bake.hcl: regenerated",
          "- .gitlab-ci/extends/.matrix.yml: regenerated",
        ].join('\n')})
        git.dirs.should eq [File.join(env.dir, "docker-images/traefik")]
      end
    end

    it "skips when the repository has nothing to commit" do
      with_committer do |committer, git|
        nothing_staged(git)

        committer.commit_donico("traefik", "1.15.0").should eq({:skip, nil})
      end
    end

    it "reports a refused commit" do
      with_committer do |committer, git|
        git.answer("commit", code: 1, text: "nothing to commit\n")

        committer.commit_donico("traefik", "1.15.0").should eq({:fail, "nothing to commit"})
      end
    end
  end

  describe "#commit_config" do
    # The gem committed the whole index, so a file the owner had staged in the
    # configuration repository left under the README's title. This departs
    # from the gem on purpose: the question and the commit name README.md.
    it "commits only the root README, in the configuration repository, whatever else is staged" do
      with_committer do |committer, git, env|
        committer.commit_config([row, row(image: "grafana", latest: "13.1.1")]).should eq({:ok, nil})

        git.lines.should eq [
          "git add README.md",
          "git diff --cached --quiet -- README.md",
          "git commit -m docs: bump traefik, grafana versions in README -m - README.md: regenerated tags for traefik, grafana -- README.md",
        ]
        git.dirs.should eq [env.dir]
        message(git, ["README.md"]).should eq({"docs: bump traefik, grafana versions in README",
                                               "- README.md: regenerated tags for traefik, grafana"})
      end
    end

    # Eleven images would pass the ~70 character title limit: the title becomes
    # a count and the body carries the names.
    it "falls back to a count when there are too many images to name" do
      with_committer do |committer, git|
        names = %w[a b c d e f g h i j k]
        committer.commit_config(names.map { |name| row(image: name) })

        title, body = message(git, ["README.md"])
        title.should eq "docs: bump 11 image versions in README"
        body.should eq "- README.md: regenerated tags for a, b, c, d, e, f, g, h, i, j, k"
      end
    end

    it "names five images and counts six" do
      with_committer do |committer, git|
        committer.commit_config(%w[a b c d e].map { |name| row(image: name) })
        message(git, ["README.md"])[0].should eq "docs: bump a, b, c, d, e versions in README"
      end
      with_committer do |committer, git|
        committer.commit_config(%w[a b c d e f].map { |name| row(image: name) })
        message(git, ["README.md"])[0].should eq "docs: bump 6 image versions in README"
      end
    end

    # The question is about the index, not the working tree: an unrelated edit
    # in the configuration repository must not make an unchanged README look
    # committable.
    it "skips when the README did not change, however dirty the repository is elsewhere" do
      with_committer do |committer, git|
        nothing_staged(git).answer("status --porcelain", text: " M unrelated.rb\n")

        committer.commit_config([row]).should eq({:skip, nil})
        git.lines("commit").should be_empty
        git.lines("status").should be_empty
      end
    end
  end

  describe "#push" do
    it "pushes an image repository to master" do
      with_committer do |committer, git, env|
        committer.push("traefik").should eq({:ok, nil})

        git.calls.map { |call| {call.dir, call.line} }.should eq [{File.join(env.dir, "docker-images/traefik"), "git push origin master"}]
      end
    end

    it "pushes the configuration repository when given no image" do
      with_committer do |committer, git, env|
        committer.push(nil)

        git.calls.map { |call| {call.dir, call.line} }.should eq [{env.dir, "git push origin master"}]
      end
    end

    it "reports a rejected push with git's message" do
      with_committer do |committer, git|
        git.answer("push", code: 1, text: "rejected: non-fast-forward\n")

        committer.push("traefik").should eq({:fail, "rejected: non-fast-forward"})
      end
    end
  end
end
