require "../../env"
require "../../runner"
require "../regenerate"
require "../repos"
require "./row"

module Donico
  module Fleet
    module Versions
      # Commits and pushes the bumps, in the two repositories a version update
      # touches: each image repository (donico.yml, the generated files and its
      # README) and the configuration repository itself (the regenerated root
      # README).
      #
      # Commit messages follow the repositories' Conventional Commits convention:
      # `build:` for an image, `docs:` for the root README. No Co-Authored-By
      # trailer, these commits are the tool's.
      #
      # Push is a separate call on purpose: it is the irreversible step (the CI
      # pipeline builds and publishes), so the caller decides when.
      #
      # Never raises: returns an `Outcome` with `:ok`, `:skip` (nothing to
      # commit) or `:fail`.
      class Committer
        BRANCH = "master"

        # Above this many images the title would exceed the ~70 character limit
        # commitlint enforces, so it degrades to a count.
        MAX_NAMED_IMAGES = 5

        IMAGE_BODY = [
          "- donico.yml: new version",
          "- docker-bake.hcl: regenerated",
          "- .gitlab-ci/extends/.matrix.yml: regenerated",
          "- README.md: regenerated tags",
        ].join('\n')

        # `build:` and not `feat:`: the donico pin is a dependency, and the
        # repositories reserve `feat` for features.
        DONICO_BODY = [
          "- mise.toml: new donico version",
          "- docker-bake.hcl: regenerated",
          "- .gitlab-ci/extends/.matrix.yml: regenerated",
        ].join('\n')

        def initialize(@repos : Repos, @env : Env, @runner_for : String -> Runner)
        end

        # Commits an image's bump in its own repository.
        def commit_image(row : Row) : Outcome
          commit(@repos.path(row.image), ["-A"], "build: bump to #{row.latest}", IMAGE_BODY)
        end

        # Commits an image's donico bump in its own repository.
        def commit_donico(image : String, version : String) : Outcome
          commit(@repos.path(image), ["-A"], "build: bump to donico #{version}", DONICO_BODY)
        end

        # Commits the root README regenerated for `rows`, in the configuration
        # repository.
        #
        # `update-readme` regenerates every line from the donico.yml files, so this
        # commit carries every README difference, including images bumped outside
        # this run. The title names the images this run bumped; the content is
        # whatever the README truly says. That is the honest trade: guessing which
        # lines belong to the run would mean parsing a diff.
        #
        # This departs from the gem on purpose: the gem asked whether anything
        # was staged and committed the whole index, so a file the owner had
        # staged in this working repository left under the README's title.
        # Here the question and the commit both name README.md, and whatever
        # else is staged stays staged. The image repositories need no such
        # care: they are checked clean before the bump writes anything.
        def commit_config(rows : Array(Row)) : Outcome
          images = rows.map(&.image)
          commit(@repos.root, ["README.md"], config_title(images), "- README.md: regenerated tags for #{images.join(", ")}",
            only: ["README.md"])
        end

        # Pushes `image`'s repository, or the configuration repository itself when
        # `image` is nil.
        def push(image : String?) : Outcome
          code, text = @runner_for.call(image ? @repos.path(image) : @repos.root).capture("git", ["push", "origin", BRANCH])
          code.zero? ? {:ok, nil} : {:fail, text.strip}
        end

        # `only`, when given, limits the question and the commit to those
        # paths (`git commit -- <paths>`): the rest of the index is left as it
        # was, staged and uncommitted.
        private def commit(dir : String, add : Array(String), title : String, body : String,
                           only : Array(String) = [] of String) : Outcome
          runner = @runner_for.call(dir)
          code, text = runner.capture("git", ["add"] + add)
          # A refused add stages nothing, and "nothing staged" below would then
          # read as "nothing to commit" for a repository left modified.
          return {:fail, text.strip} unless code.zero?
          return {:skip, nil} if nothing_staged?(runner, only)

          code, text = runner.capture("git", ["commit", "-m", title, "-m", body] + pathspec(only))
          code.zero? ? {:ok, nil} : {:fail, text.strip}
        end

        private def pathspec(paths : Array(String)) : Array(String)
          paths.empty? ? [] of String : ["--"] + paths
        end

        # Nothing staged: committing would be refused. The question is about the
        # INDEX, not the working tree: `git commit` without -a commits what was
        # staged and nothing else, so the tree's other changes have no bearing on
        # it. `git status --porcelain` conflated the two: in the configuration
        # repository, a working repository, someone's unrelated edit made an
        # unchanged README look committable, git refused, and the run reported a
        # failure whose message was "On branch master".
        #
        # `git diff --cached --quiet` exits 0 when the index matches HEAD (for
        # `paths` only, when given).
        private def nothing_staged?(runner : Runner, paths : Array(String)) : Bool
          code, _ = runner.capture("git", ["diff", "--cached", "--quiet"] + pathspec(paths))
          code.zero?
        end

        private def config_title(images : Array(String)) : String
          return "docs: bump #{images.size} image versions in README" if images.size > MAX_NAMED_IMAGES

          "docs: bump #{images.join(", ")} versions in README"
        end
      end
    end
  end
end
