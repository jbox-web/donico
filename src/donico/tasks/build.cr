require "../env"
require "../image"
require "../runner"
require "./secrets"

module Donico
  module Tasks
    # Runs `docker buildx bake` on the row's build target, with BUILD_DATE
    # added to the inherited environment (the bakefile reads it from there),
    # and the process is replaced: with the real runner `run` never returns.
    class Build
      def initialize(@image : Image, @env : Env, @runner : Runner)
      end

      def run : Int32
        Secrets.verify!(@image, @env)
        @runner.exec("docker", ["buildx", "bake", @image.build_target], @image.bake_env)
      end
    end
  end
end
