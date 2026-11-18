require "../env"
require "../error"
require "../rootfs"
require "../runner"

module Donico
  module Tasks
    # Assembles the tarballs of a row into one multi-arch image and pushes it:
    # `docker buildx build` on the repository's Dockerfile (`FROM scratch`,
    # `ADD` of the tarball of TARGETARCH), straight to the registry. The image
    # never exists in the local docker. The Debian version, which gives two of
    # the four tags, is read from the tarball of the first arch. The process
    # is replaced by the build: with the real runner `run` never returns.
    #
    # The command line is the one of danico's bin/push.
    class RootfsPush
      DEBIAN_VERSION = "etc/debian_version"

      def initialize(@rootfs : Rootfs, @env : Env, @runner : Runner)
      end

      def run : Int32
        verify!
        debian_version = read_debian_version(@rootfs.tarball(@rootfs.archs.first))
        tags = @rootfs.tags(debian_version)

        @env.stdout.puts "Pushing Docker image: #{@rootfs.distro} (tags: #{tags.map(&.rpartition(':').last).join('/')})"
        args = [
          "buildx", "build", "--no-cache", "--platform", @rootfs.platforms,
          "--build-arg", "DISTRO=#{@rootfs.distro}", "--build-arg", "BUILD_TIMESTAMP=#{@rootfs.timestamp}",
        ]
        tags.each { |tag| args << "-t" << tag }
        args << "-o" << "type=registry" << "."
        @runner.exec("docker", args)
      end

      # Every tarball the Dockerfile will ADD. Without this, a tarball built
      # the day before (another default timestamp) or never built ends as a
      # tar or a buildx message that names neither the cause nor the remedy.
      private def verify! : Nil
        missing = @rootfs.archs.map { |arch| @rootfs.tarball(arch) }.reject { |tarball| File.file?(File.join(@env.dir, tarball)) }
        return if missing.empty?
        raise ProblemList.new(missing.map { |tarball| "#{tarball} not found: run `#{NAME} #{@rootfs.task_prefix}:build` first" })
      end

      # A released Debian holds "13.2" there; testing and unstable hold
      # "trixie/sid", which is neither a version nor a valid tag.
      private def read_debian_version(tarball : String) : String
        code, text = @runner.output("tar", ["-O", "-xf", tarball, DEBIAN_VERSION])
        unless code.zero?
          raise EnvironmentError.new("cannot read #{DEBIAN_VERSION} from #{tarball} (tar exited with #{code})")
        end
        version = text.strip
        return version if version.matches?(/\A\d+(\.\d+)*\z/)
        raise EnvironmentError.new(%(#{DEBIAN_VERSION} of #{tarball} holds "#{version}", which is not a Debian release number))
      end
    end
  end
end
