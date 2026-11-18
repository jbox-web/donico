require "../../env"
require "../../runner"
require "../donico_pin"
require "../readme"
require "../regenerate"
require "../../version"
require "../repos"
require "./row"
require "./scanner"

module Donico
  module Fleet
    module Versions
      # Applies one image's version bump: rewrites the version in donico.yml, then
      # regenerates the derived files (docker-bake.hcl and the CI matrix) with the
      # running binary.
      #
      # Deliberately does no git work beyond the questions that decide whether
      # the repository may be touched — see Committer. Whatever is wrong with a
      # repository is an `Outcome` with `:fail` (`:ok` otherwise), so one bad
      # repository does not abort a batch. What is wrong with the machine
      # raises: `git` missing from `PATH` (an `EnvironmentError` from the
      # runner, in `unfit_reason`), or an unexpected error of the
      # regeneration, raised once donico.yml holds its text again.
      #
      # `regenerate` is `Regenerate.call`; the specs give one that raises.
      class Bumper
        def initialize(@repos : Repos, @env : Env, @runner_for : String -> Runner,
                       @regenerate : Env, String -> Outcome = ->(env : Env, dir : String) { Regenerate.call(env, dir) })
        end

        def call(row : Row) : Outcome
          dir = @repos.path(row.image)
          return {:fail, "#{row.image} is not cloned (run `donico-manager repos clone`)"} unless @repos.cloned?(row.image)

          path = donico_path(dir) || return {:fail, "#{row.image} has no donico.yml"}
          if refusal = unfit_reason(dir, path, row)
            return {:fail, refusal}
          end

          latest = row.latest || return {:fail, "#{row.image} has no upstream version to bump to"}
          original = File.read(path)
          File.write(path, rewrite(original, row, latest))
          # A refused regeneration has written nothing else (GenerateFiles
          # renders both files before writing either, and restores them if a
          # write fails), so putting the text back leaves the repository as it
          # was: a failed repository must not be left dirty, or the next run
          # refuses it for "uncommitted changes". The same holds when the
          # regeneration raises, and the exception then goes on.
          begin
            outcome = @regenerate.call(@env, dir)
          rescue error : Exception
            File.write(path, original)
            raise error
          end
          File.write(path, original) if outcome[0] == :fail
          outcome
        end

        # Found the way the README generators find it, so a repository they
        # list is one the bumper finds.
        private def donico_path(dir : String) : String?
          ImageConfig.path(dir)
        end

        # Why the repository must not be touched, or nil when it is fit. Checked
        # before any write.
        private def unfit_reason(dir : String, path : String, row : Row) : String?
          DonicoPin.unfit_reason(@runner_for.call(dir)) || stale_reason(path, row) || pin_reason(dir)
        end

        # The scan may be minutes old: if donico.yml moved since, the
        # substitution would silently target nothing (or the wrong line).
        private def stale_reason(path : String, row : Row) : String?
          match = Scanner::VERSION_LINE.match(File.read(path))
          return if match && match[2] == row.current

          "donico.yml is no longer at #{row.current} (found #{match ? match[2] : "nothing"})"
        end

        # The files donico regenerates are those of the running binary: a
        # repository pinned to another donico would get another donico's output.
        # A repository without a pin is bumped.
        private def pin_reason(dir : String) : String?
          path = File.join(dir, "mise.toml")
          return unless File.file?(path)

          # Each pin line counts: a mise.toml may pin through both backends.
          pinned = File.read(path).scan(DonicoPin::LINE).map(&.[2]).find { |version| version != Donico::VERSION }
          return if pinned.nil?

          "pinned to donico #{pinned}, this binary is #{Donico::VERSION}"
        end

        # Replaces the version in the first matching line only, reusing the
        # quoting found in the file: a bare 4.40 would be re-read by YAML as the
        # float 4.4, breaking both the image tag and the build arg.
        private def rewrite(text : String, row : Row, latest : String) : String
          text.sub(Scanner::VERSION_LINE) do |line, match|
            quote = match[1]
            line.sub("#{quote}#{row.current}#{quote}", "#{quote}#{latest}#{quote}")
          end
        end
      end
    end
  end
end
