require "../env"
require "../error"
require "../rootfs"
require "../runner"

module Donico
  module Tasks
    # Builds the root filesystem of a row, one arch after the other, each in a
    # container of the debuerreotype image running the row's script. The
    # tarballs land in build/, which the container sees as its working
    # directory; config/ is mounted next to it for the files the script copies
    # into the image. The first arch that fails ends the task with its exit
    # code.
    #
    # INT and TERM are trapped for the length of the builds: the signal is
    # passed on to the running `docker run`, which stops its container, no
    # further arch is started and the task answers 128 + the signal. Without
    # this, a donico killed alone (a cancelled CI job) would leave a
    # privileged container writing root-owned files into build/.
    #
    # The `docker run` line is the one of danico's bin/build, itself borrowed
    # from debuerreotype's docker-run.sh.
    class RootfsBuild
      CONFIG_DIR = "config"

      def initialize(@rootfs : Rootfs, @env : Env, @runner : Runner, @debuerreotype_image : String)
        # The number of the signal received during `run`, 0 for none. Written
        # by the signal handler, which may run on another thread
        # (-Dpreview_mt) than the one that reads it.
        @signal = Atomic(Int32).new(0)
        @interrupted = false
      end

      def run : Int32
        verify!
        create_build_dir

        @signal.set(0)
        @interrupted = false
        trap_signals
        begin
          @rootfs.archs.each do |arch|
            break if @signal.get != 0
            @env.stdout.puts "Building #{@rootfs.distro} for linux/#{arch} (#{@rootfs.tarball(arch)})"
            code = @runner.system("docker", docker_run(arch))
            break if @signal.get != 0
            return code unless code.zero?
          end
          received = @signal.get
          @interrupted = received != 0
          @interrupted ? 128 + received : 0
        ensure
          reset_signals
        end
      end

      # True when a signal was recorded during the last `run`.
      def interrupted? : Bool
        @interrupted
      end

      # What the INT/TERM handlers do, callable without a real signal: record
      # the first one, then pass it on to the running child.
      def handle_signal(signal : Signal) : Nil
        @signal.compare_and_set(0, signal.value)
        @runner.forward(signal)
      end

      private def docker_run(arch : String) : Array(String)
        [
          "run", "--hostname", "debuerreotype", "--init", "--interactive", "--rm", "--pull", "always",
          # we ought to be able to mount/unshare
          "--cap-add", "SYS_ADMIN",
          # make sure we don't get extended attributes
          "--cap-drop", "SETFCAP",
          # AppArmor also blocks mount/unshare :)
          "--security-opt", "apparmor=unconfined",
          "--tmpfs", "/tmp:dev,exec,suid,noatime", "--env", "TMPDIR=/tmp",
          "--workdir", "/workdir",
          "--mount", "type=bind,src=#{File.join(@env.dir, Rootfs::BUILD_DIR)},dst=/workdir",
          # mount some dirs to easily inject some scripts and config files
          "--mount", "type=bind,src=#{File.join(@env.dir, CONFIG_DIR)},dst=/config",
          @debuerreotype_image, "bash", "-euc", @rootfs.script(arch),
        ]
      end

      # What would otherwise fail inside the container, minutes into the
      # build, or as a docker message about a mount: said here, before any
      # container starts.
      private def verify! : Nil
        if @env.dir.includes?(',')
          raise EnvironmentError.new("#{@env.dir} holds a comma, which docker cannot mount: move the project")
        end

        problems = [] of String
        sources = "#{CONFIG_DIR}/apt/#{@rootfs.version}-#{@rootfs.distro}.list"
        problems << "#{sources} not found: the build copies it to etc/apt/sources.list" unless file?(sources)
        no_check = "#{CONFIG_DIR}/apt/apt-no-check"
        if @rootfs.entry.eol? && !file?(no_check)
          problems << "#{no_check} not found: the build of an eol row copies it to etc/apt/apt.conf.d/"
        end
        # debuerreotype-init refuses a target that exists and is not empty:
        # what an earlier build of the same day left, finished or not.
        @rootfs.archs.each do |arch|
          left = "#{Rootfs::BUILD_DIR}/#{@rootfs.build_dir(arch)}"
          next unless leftover?(left)
          problems << "#{left} already exists: run `#{NAME} #{@rootfs.task_prefix}:clean` first"
        end
        raise ProblemList.new(problems) unless problems.empty?
      end

      # The directory may belong to root and be closed to donico: what cannot
      # be listed counts as not empty, which is what the build would find.
      private def leftover?(relative : String) : Bool
        path = File.join(@env.dir, relative)
        return false unless Dir.exists?(path)
        !Dir.empty?(path)
      rescue File::Error
        true
      end

      private def file?(relative : String) : Bool
        File.file?(File.join(@env.dir, relative))
      end

      # `--mount` refuses a source that does not exist, where `-v` would have
      # created it as root.
      # `Process.on_terminate`, which ameba prefers, cannot be undone and hides
      # which signal arrived (see Inspec, which traps for the same reasons).
      protected def trap_signals : Nil
        # ameba:disable Lint/SignalTrap
        Signal::INT.trap { |signal| handle_signal(signal) }
        # ameba:disable Lint/SignalTrap
        Signal::TERM.trap { |signal| handle_signal(signal) }
      end

      private def reset_signals : Nil
        Signal::INT.reset
        Signal::TERM.reset
      end

      private def create_build_dir : Nil
        Dir.mkdir_p(File.join(@env.dir, Rootfs::BUILD_DIR))
      rescue error : File::Error
        reason = error.os_error.try(&.message) || error.message
        raise EnvironmentError.new("cannot create #{Rootfs::BUILD_DIR}: #{reason}")
      end
    end
  end
end
