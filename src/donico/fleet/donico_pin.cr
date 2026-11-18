require "../env"
require "../runner"
require "./regenerate"
require "./repos"

module Donico
  module Fleet
    # Pins one image repository to a donico version, in the `mise.toml` that
    # installs the binary (the gem wrote a Gemfile), then regenerates the files
    # with it. No git work beyond the two questions that decide whether the
    # repository may be touched: the commit and the push are the caller's, so
    # the irreversible step stays a separate decision.
    #
    # Whatever is wrong with a repository is an `Outcome`: one bad repository
    # does not abort a batch. What is wrong with the machine raises: `git`
    # missing from `PATH` (an `EnvironmentError` from the runner, in
    # `unfit_reason`), or an unexpected error of the regeneration, raised once
    # mise.toml holds its text again.
    #
    # `regenerate` is `Regenerate.call`; the specs give one that raises.
    class DonicoPin
      BRANCH = "master"

      # A pin line of a `mise.toml`, through either backend the README
      # proposes (`"github:jbox-web/donico"` or `"aqua:jbox-web/donico"`): the
      # quoted version is its second group. `m` because the text is the whole
      # file, where Ruby's `^` matches at every line.
      LINE = /^(\s*"(?:aqua|github):jbox-web\/donico"\s*=\s*")([^"]*)(")/m

      def initialize(@repos : Repos, @env : Env, @runner_for : String -> Runner,
                     @regenerate : Env, String -> Outcome = ->(env : Env, dir : String) { Regenerate.call(env, dir) })
      end

      # The checks run in this order and the first that applies decides, so a
      # repository that is not migrated yet is skipped even when it is dirty.
      def call(image : String, version : String) : Outcome
        return {:skip, "#{image}: bump_donico is false"} unless @repos.manifest.bump_donico?(image)
        return {:skip, "#{image} is not cloned"} unless @repos.cloned?(image)

        dir = @repos.path(image)
        path = File.join(dir, "mise.toml")
        text = File.file?(path) ? File.read(path) : nil
        return {:skip, "#{image}: no donico pin in mise.toml"} unless text && LINE.matches?(text)

        if refusal = self.class.unfit_reason(@runner_for.call(dir))
          return {:fail, refusal}
        end

        # Every pin line, each keeping its backend: a mise.toml may hold both.
        File.write(path, text.gsub(LINE) { |_, match| "#{match[1]}#{version}#{match[3]}" })
        # A refused regeneration has written nothing else (GenerateFiles renders
        # both files before writing either, and restores them if a write
        # fails), so putting the pin back leaves the repository as it was: a
        # failed repository must not be left dirty, or the next run refuses it
        # for "uncommitted changes". The same holds when the regeneration
        # raises, and the exception then goes on.
        begin
          outcome = @regenerate.call(@env, dir)
        rescue error : Exception
          File.write(path, text)
          raise error
        end
        File.write(path, text) if outcome[0] == :fail
        outcome
      end

      # Why the repository must not be touched, or nil when it is fit: checked
      # before any write, since a bump mixed into someone else's uncommitted
      # work is worse than a skipped image. The exit status matters as much as
      # the output: a directory that is not a repository answers with an error
      # and nothing on stdout, which would read as "clean".
      def self.unfit_reason(runner : Runner) : String?
        code, text = runner.capture("git", ["status", "--porcelain"])
        return "git status failed: #{text.strip}" unless code.zero?
        return "uncommitted changes in the repo" unless text.strip.empty?

        _, text = runner.capture("git", ["rev-parse", "--abbrev-ref", "HEAD"])
        branch = text.strip
        "on #{branch}, not #{BRANCH}" unless branch == BRANCH
      end
    end
  end
end
