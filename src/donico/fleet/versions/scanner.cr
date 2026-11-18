require "yaml"
require "../readme"
require "../repos"
require "./github"
require "./policy"
require "./row"

module Donico
  module Fleet
    module Versions
      # Walks the cloned image repositories, reads each donico.yml and resolves
      # its upstream version, producing one Row per tracked image.
      #
      # Lookups run on fibers, at most `pool_size` at a time (network-bound, and
      # the API caps concurrency anyway). A failing lookup yields an Error row
      # instead of aborting: one unreachable repository must not cost the others.
      class Scanner
        POOL_SIZE = 5

        # The version line, e.g. `  - version: "4.39"`. Captured from the raw
        # text rather than from the parsed YAML on purpose: the parser would turn
        # an unquoted `4.40` into the float 4.4 and lose the quoting style the
        # bumper needs to preserve. `m` because the text is the whole file, where
        # Ruby's `^` matches at every line.
        VERSION_LINE = /^\s*-?\s*version:\s*(["']?)([^"'\s]+)\1/m

        private record Entry, image : String, current : String, quoted : Bool, repo : String

        # What a worker hands back: the row, or the rate limit that ends the scan.
        private alias Outcome = Row | Github::RateLimited

        def initialize(@repos : Repos, @github : Github, @pool_size : Int32 = POOL_SIZE)
          @policy = Policy.new(@repos.manifest)
        end

        # The rows sorted by image name. Yields (done, total) as each image
        # resolves, from the calling fiber only. A rate limit leaves the scan.
        def call(& : Int32, Int32 ->) : Array(Row)
          entries = tracked
          rows = [] of Row
          resolve_all(entries) do |done, row|
            rows << row
            yield done, entries.size
          end
          rows.sort_by!(&.image)
        end

        # An entry for every image worth querying: a readable donico.yml (or
        # danico.yml) with both a version and a github_repo, and not on the
        # skip list. The workspace is walked, not the manifest's list.
        private def tracked : Array(Entry)
          paths = Dir.glob(File.join(@repos.workspace, "*", "{donico,danico}.yml"))
          paths.sort!.compact_map do |path|
            image = File.basename(File.dirname(path))
            next if @policy.skip?(image)

            entry_for(image, path)
          end
        end

        private def entry_for(image : String, path : String) : Entry?
          text = File.read(path)
          match = VERSION_LINE.match(text)
          repo = ImageConfig.string?(top_level(text), "github_repo")
          return if match.nil? || repo.nil? || repo.empty?

          Entry.new(image, match[2], !match[1].empty?, repo)
        end

        # The top-level mapping of a YAML text; empty when it does not parse,
        # is empty or is not a mapping.
        private def top_level(text : String) : Hash(YAML::Any, YAML::Any)
          YAML.parse(text).as_h? || {} of YAML::Any => YAML::Any
        rescue YAML::ParseException
          {} of YAML::Any => YAML::Any
        end

        # Resolves every entry on at most `pool_size` fibers and yields
        # (done, row) from this fiber as each one finishes.
        #
        # No fiber can be left blocked, whatever happens: the jobs are all
        # queued in a closed channel, and the results channel has room for every
        # entry, so a worker never waits to send. A rate limit makes the caller
        # raise at once; the flag stops the other workers from taking a further
        # job, and the one lookup each may still have in flight ends on its own
        # and drops its result into the channel.
        private def resolve_all(entries : Array(Entry), & : Int32, Row ->) : Nil
          return if entries.empty?

          jobs = Channel(Entry).new(entries.size)
          outcomes = Channel(Outcome).new(entries.size)
          entries.each { |entry| jobs.send(entry) }
          jobs.close
          stopped = Atomic(Int32).new(0)

          Math.min(@pool_size, entries.size).times do
            spawn do
              while stopped.get == 0 && (job = jobs.receive?)
                outcome = lookup(job)
                stopped.set(1) if outcome.is_a?(Github::RateLimited)
                outcomes.send(outcome)
              end
            end
          end

          entries.size.times do |done|
            case outcome = outcomes.receive
            in Github::RateLimited
              raise outcome
            in Row
              yield done + 1, outcome
            end
          end
        end

        # One image's failure is one image's error row, whatever the failure is:
        # a timeout, a reset connection or a TLS handshake included. RateLimited
        # is the exception, deliberately: it is not one image's problem but the
        # scan's, since every remaining lookup would fail the same way. Swallowed
        # here it produced one "API error" row per image and not one saying
        # "throttled", the very silence Github raises it to avoid.
        private def lookup(entry : Entry) : Outcome
          latest = @github.resolve(entry.repo, @policy.constraint_for(entry.image))
          build_row(entry, latest)
        rescue error : Github::RateLimited
          error
        rescue Exception
          build_row(entry, nil)
        end

        private def build_row(entry : Entry, latest : String?) : Row
          Row.new(
            image: entry.image,
            current: entry.current,
            latest: latest,
            state: @policy.classify(entry.image, entry.current, latest),
            repo: entry.repo,
            quoted: entry.quoted,
          )
        end
      end
    end
  end
end
