require "../env"
require "../rootfs"
require "../runner"

module Donico
  module Tasks
    # Removes what the builds of a row left in build/: for each arch, every
    # directory and tarball named `<distro>-<arch>-*`, whatever its timestamp.
    # They were written by root in the build container, so the removal goes
    # through `sudo` unless donico runs as root itself (the CI case). One
    # `rm` per arch, as in danico's bin/clean; the first that fails ends the
    # task with its exit code.
    class RootfsClean
      def initialize(@rootfs : Rootfs, @env : Env, @runner : Runner, @root : Bool = LibC.getuid == 0)
      end

      def run : Int32
        @rootfs.archs.each do |arch|
          paths = leftovers(arch)
          next if paths.empty?
          code = @root ? @runner.system("rm", ["-rf"] + paths) : @runner.system("sudo", ["rm", "-rf"] + paths)
          return code unless code.zero?
        end
        0
      end

      # The entries are listed here rather than matched by a shell: no shell
      # runs, and the project path may hold characters a pattern would read.
      private def leftovers(arch : String) : Array(String)
        build = File.join(@env.dir, Rootfs::BUILD_DIR)
        return [] of String unless Dir.exists?(build)
        prefix = "#{@rootfs.distro}-#{arch}-"
        Dir.children(build).select(&.starts_with?(prefix)).sort!.map { |name| File.join(build, name) }
      end
    end
  end
end
