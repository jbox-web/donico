require "ecr"

require "./config"
require "./matrix_entry"

module Donico
  # The values derived from one matrix row of the debuerreotype backend: a
  # Debian root filesystem built once per arch by debuerreotype, each one
  # packed in a tarball, the tarballs then assembled into one multi-arch
  # image `<registry>/<distro>`. It is to that backend what Image is to bake.
  #
  # An arch is named here the way docker names it (`amd64`, `386`): the part
  # after `linux/` of the row's `archs`. It is what the Dockerfile of the
  # repository reads as TARGETARCH to pick its tarball, so it names the build
  # directory and the tarball. debootstrap is given the name Debian uses
  # (`i386`), from MatrixEntry::DEBIAN_ARCHS.
  class Rootfs
    # Where the tarballs are written, under the project directory. It is
    # mounted as the working directory of the build container.
    BUILD_DIR = "build"

    getter registry : String
    getter distro : String
    getter version : String
    getter entry : MatrixEntry

    def self.all(config : Config) : Array(Rootfs)
      config.matrix.map { |entry| new(config, entry) }
    end

    def initialize(@config : Config, @entry : MatrixEntry)
      @registry = @config.registry
      @distro = @entry.distro
      @version = @entry.version
    end

    # The row's own, else the day before the run.
    def timestamp : String
      @entry.timestamp || @config.rootfs_timestamp
    end

    def archs : Array(String)
      @entry.archs.map(&.lchop("linux/"))
    end

    # The value of `docker buildx build --platform`.
    def platforms : String
      @entry.archs.join(",")
    end

    # The directory of the root filesystem of `arch`, inside BUILD_DIR.
    def build_dir(arch : String) : String
      "#{distro}-#{arch}-#{timestamp}"
    end

    # The tarball of `arch`, relative to the project directory.
    def tarball(arch : String) : String
      "#{BUILD_DIR}/#{build_dir(arch)}.tar"
    end

    def image : String
      "#{registry}/#{distro}"
    end

    # The four tags of a push, in danico's order. `debian_version` is the
    # content of etc/debian_version in the root filesystem ("13.2").
    def tags(debian_version : String) : Array(String)
      major = debian_version.partition('.').first
      ["latest", major, debian_version, timestamp].map { |tag| "#{image}:#{tag}" }
    end

    def task_prefix : String
      @entry.task_prefix
    end

    # What bash runs in the build container for `arch`: the recipe with its
    # comments and empty lines removed, the commands joined by `;`. This is
    # what danico's Rakefile did with templates/debian-build.erb, and the
    # result is the same text, byte for byte.
    def script(arch : String) : String
      recipe = Script.new(@entry, MatrixEntry::DEBIAN_ARCHS[arch], build_dir(arch), @config.build_proxy).to_s
      recipe.split('\n').reject { |line| line.empty? || line.starts_with?('#') }.join(';')
    end

    # The recipe itself. The template is danico's ERB one, line for line: only
    # the names of the values changed, and the proxy test, which is now "a
    # proxy is in use" where it was "ENABLE_APT_PROXY is true".
    private class Script
      def initialize(@entry : MatrixEntry, @arch : String, @build_dir : String, @proxy : String?)
      end

      ECR.def_to_s "#{__DIR__}/rootfs_script.ecr"
    end
  end
end
