require "../../error"
require "../regenerate"
require "./row"

module Donico
  module Fleet
    module Versions
      # Composes the whole update: scan, then the three-stage apply, then the
      # push. This is where the ORDER lives, and the order is not free.
      #
      # The image READMEs are rewritten inside every image repository, so they
      # must be generated after all the bumps and before any commit: otherwise
      # each image commit would miss its own regenerated README, and a second
      # commit would be needed everywhere.
      #
      #   1. bump every chosen image (donico.yml + generate-files)
      #   2. once: the image READMEs, then the root README (`readmes`)
      #   3. commit each image that bumped cleanly, then the root README commit
      #
      # The push is a separate call: it is the irreversible step (the pipeline
      # builds and publishes). It does no I/O of its own and starts no fiber: it
      # calls its collaborators and the caller's block, in the caller's fiber.
      #
      # Generic over its three collaborators (a `Scanner`, a `Bumper`, a
      # `Committer` in production) so that the specs drive it with small fakes
      # that record the order of the calls, without touching those classes.
      class Updater(S, B, C)
        def initialize(@scanner : S, @bumper : B, @committer : C, @readmes : -> Nil)
        end

        # The rows of the whole workspace. Yields (done, total) as the scan
        # advances.
        def scan(& : Int32, Int32 ->) : Array(Row)
          @scanner.call { |done, total| yield done, total }
        end

        # Bumps, regenerates and commits `rows`. Yields (status, row, message)
        # per image: once after its bump, and again if a later stage downgrades
        # it. A nil row names the configuration repository, which carries the
        # regenerated root README and is not an image. Returns the rows that
        # produced a real commit.
        def apply(rows : Array(Row), & : Symbol, Row?, String? ->) : Array(Row)
          bumped = rows.select do |row|
            status, message = @bumper.call(row)
            yield status, row, message
            status == :ok
          end
          return [] of Row if bumped.empty?

          if error = regenerate_readmes
            bumped.each { |row| yield :fail, row, "README regeneration failed: #{error}" }
            return [] of Row
          end

          committed = bumped.select do |row|
            status, message = @committer.commit_image(row)
            yield status, row, message unless status == :ok
            status == :ok
          end
          return committed if committed.empty?

          status, message = @committer.commit_config(committed)
          yield status, nil, message if status == :fail
          committed
        end

        # Pushes each row's repository, then the configuration repository
        # itself. Yields (status, row, message) per image, then once more with a
        # nil row for the configuration repository: pushing every image and
        # failing to push the README that describes them leaves the fleet split.
        def push(rows : Array(Row), & : Symbol, Row?, String? ->) : Array(Row)
          return [] of Row if rows.empty?

          rows.each do |row|
            status, message = @committer.push(row.image)
            yield (status == :ok ? :pushed : :fail), row, message
          end
          status, message = @committer.push(nil)
          yield (status == :ok ? :pushed : :fail), nil, message
          rows
        end

        # The failure message of the README generation, or nil on success. A
        # silently ignored failure would let every image commit go out without
        # its own regenerated README. The rescue is wide on purpose, as in the
        # gem: the pipeline guarantees that a failed generation downgrades every
        # bumped row and commits nothing, and the rows are already written by
        # now. An unwritable README.md raises a File::Error, not a
        # Donico::Error, and must not escape after every bump was reported :ok.
        private def regenerate_readmes : String?
          @readmes.call
          nil
        rescue error : Exception
          error.message
        end
      end
    end
  end
end
