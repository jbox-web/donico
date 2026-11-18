require "./policy"

module Donico
  module Fleet
    module Versions
      # One image's version state: what donico.yml says, what upstream says, and
      # how the two compare. `quoted` records whether the YAML scalar is quoted,
      # so a bump can preserve the style (an unquoted "4.40" would be re-read as
      # the float 4.4, breaking the tag and the build arg).
      record Row, image : String, current : String, latest : String?, state : State, repo : String, quoted : Bool do
        def url : String
          "https://github.com/#{repo}"
        end

        def update? : Bool
          state.update?
        end

        # The version as donico.yml holds it, quotes included: a quoted scalar
        # is the one a careless bump turns into a float, so the report shows it
        # verbatim.
        def display_current : String
          quoted ? %("#{current}") : current
        end

        # Which segment moved: :major (first), :minor (second), :patch (deeper).
        # nil when the two versions are identical or not both numeric. The
        # version schemes in use range from two segments (seaweedfs "4.40") to
        # four (jruby "10.1.1.0"), so the rank of the first difference is the
        # only rule that holds across all of them. A missing segment is not a
        # zero: "1.2" and "1.2.0" differ, at the third rank.
        def bump_kind : Symbol?
          from = segments(current) || return
          to = segments(latest) || return

          rank = (0...Math.max(from.size, to.size)).find { |index| from[index]? != to[index]? } || return
          case rank
          when 0 then :major
          when 1 then :minor
          else        :patch
          end
        end
      end

      # Reopened rather than written in the `record` block: `crystal doc`
      # re-parses that block and refuses a `private def` in it.
      struct Row
        # Splits a version into integer segments, or nil when it is not numeric.
        # Dots and dashes both separate (1.26.3-01 -> [1, 26, 3, 1]).
        private def segments(version : String?) : Array(Int64)?
          return unless version && version.matches?(/\A\d+([.-]\d+)*\z/)

          version.split(/[.-]/).map { |part| part.to_i64? || return }
        end
      end
    end
  end
end
