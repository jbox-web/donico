require "../manifest"

module Donico
  module Fleet
    module Versions
      # How a (current, latest) pair classifies.
      #
      #   Unfixed - donico.yml tracks "latest": nothing to compare
      #   Error   - the upstream lookup returned nothing
      #   Pinned  - deliberately held
      #   Ok      - identical
      #   Update  - an update is available
      enum State
        Update
        Error
        Unfixed
        Pinned
        Ok
      end

      # Which images are tracked, which are deliberately held back, and how a
      # (current, latest) pair is classified. No I/O, no network: everything it
      # knows comes from the manifest it is built with, which is what lets a
      # second fleet hold other images back without touching the code.
      class Policy
        def initialize(@manifest : Manifest)
        end

        # Images with no upstream version to track (their own tooling sets it).
        def skip?(image : String) : Bool
          !@manifest.check_versions?(image)
        end

        # Images deliberately kept on their current version: upstream is
        # reported for information, never as an available update.
        def pinned?(image : String) : Bool
          @manifest.pinned?(image)
        end

        # The minor series `image` is held to, or nil when it tracks the latest.
        def constraint_for(image : String) : String?
          @manifest.constraint(image)
        end

        # Classifies an image from its donico.yml version and the resolved
        # upstream one. Both are expected already normalised (see
        # `Github.strip_prefix`).
        def classify(image : String, current : String, latest : String?) : State
          return State::Unfixed if current == "latest"
          return State::Error if latest.to_s.empty?
          return State::Pinned if pinned?(image)
          return State::Ok if current == latest

          State::Update
        end
      end
    end
  end
end
