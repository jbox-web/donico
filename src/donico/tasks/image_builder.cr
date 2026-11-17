require "../config"
require "../env"

module Donico
  module Tasks
    # Prints the backend name alone on a line: CI templates branch on it,
    # where grepping donico.yml for "bake" matched the word anywhere.
    class ImageBuilder
      def initialize(@config : Config, @env : Env)
      end

      def run : Int32
        @env.stdout.puts @config.image_builder
        0
      end
    end
  end
end
