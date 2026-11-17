require "json"

require "../config"
require "../env"
require "../image"

module Donico
  module Tasks
    # Prints the resolved matrix as JSON, one object per row, for the
    # scripts that used to iterate the Ruby gem's configuration.
    class Matrix
      def initialize(@config : Config, @env : Env)
      end

      def run : Int32
        json = JSON.build(indent: 2) do |builder|
          builder.array do
            Image.all(@config).each { |image| row(builder, image) }
          end
        end
        @env.stdout.puts json
        0
      end

      private def row(builder : JSON::Builder, image : Image) : Nil
        builder.object do
          builder.field "name", image.name
          builder.field "version", image.version
          builder.field "distro", image.distro
          builder.field "archs", image.entry.archs
          builder.field "dockerfile", image.entry.dockerfile
          builder.field "build_args", image.raw_build_args
          builder.field "test_args", image.entry.test_args
          builder.field "tags", image.entry.tags
          builder.field "secret_envs", image.entry.secret_envs
          builder.field "secret_files", image.entry.secret_files
          builder.field "test_variants", image.entry.test_variants
          builder.field "login_env", image.entry.login_env
          builder.field "build_tag", image.build_tag
          builder.field "prod_tags", image.prod_tags
          builder.field "build_target", image.build_target
          builder.field "push_target", image.push_target
        end
      end
    end
  end
end
