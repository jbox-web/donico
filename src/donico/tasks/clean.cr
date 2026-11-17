require "../env"
require "../image"
require "../runner"

module Donico
  module Tasks
    # Removes the build tag. On failure the captured text is the only
    # explanation docker gives, so it is printed before returning 1.
    class Clean
      def initialize(@image : Image, @env : Env, @runner : Runner)
      end

      def run : Int32
        code, text = @runner.capture("docker", ["rmi", @image.build_tag])
        return 0 if code == 0
        @env.stdout.puts text
        1
      end
    end
  end
end
