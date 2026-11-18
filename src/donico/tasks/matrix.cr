require "json"

require "../config"
require "../env"
require "../image"
require "../rootfs"

module Donico
  module Tasks
    # Prints the resolved matrix as JSON, one object per row, for the
    # scripts that used to iterate the Ruby gem's configuration. The fields
    # of a row are those of its backend.
    class Matrix
      def initialize(@config : Config, @env : Env)
      end

      def run : Int32
        json = JSON.build(indent: 2) do |builder|
          builder.array do
            if @config.debuerreotype?
              Rootfs.all(@config).each { |rootfs| row(builder, rootfs) }
            else
              Image.all(@config).each { |image| row(builder, image) }
            end
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

      # The proxy and the debootstrap mirror are left out: either URL may
      # carry credentials, and this output ends in CI logs.
      private def row(builder : JSON::Builder, rootfs : Rootfs) : Nil
        builder.object do
          builder.field "distro", rootfs.distro
          builder.field "version", rootfs.version
          builder.field "archs", rootfs.entry.archs
          builder.field "eol", rootfs.entry.eol?
          builder.field "debootstrap_opts", rootfs.entry.debootstrap_opts
          builder.field "timestamp", rootfs.timestamp
          builder.field "image", rootfs.image
          builder.field "tarballs", rootfs.archs.map { |arch| rootfs.tarball(arch) }
        end
      end
    end
  end
end
