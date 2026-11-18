require "option_parser"

require "./config"
require "./dotenv"
require "./env"
require "./error"
require "./image"
require "./inspec"
require "./licenses"
require "./rootfs"
require "./runner"
require "./ruby_list"
require "./tasks/build"
require "./tasks/clean"
require "./tasks/generate_files"
require "./tasks/image_builder"
require "./tasks/lint_dockerfile"
require "./tasks/login"
require "./tasks/matrix"
require "./tasks/push"
require "./tasks/rootfs_build"
require "./tasks/rootfs_clean"
require "./tasks/rootfs_push"
require "./tasks/test"
require "./tool_images"
require "./version"

module Donico
  # Command line front-end. It never calls `exit` and never touches the global
  # STDOUT/STDERR directly: both streams are injected and `#run` returns the
  # exit code, so specs drive it in-process. Only src/donico.cr turns that code
  # into a process exit. `dir`, `vars` and `now` are injected for the same
  # reason: specs run several projects without `Dir.cd`, on a controlled
  # environment and a fixed clock.
  class CLI
    BANNER = "Usage: #{NAME} <task> [options]"

    # The built-in tasks. The registry (parser, help, "unknown task" list) is
    # this enum and `dispatch` is an exhaustive `case ... in` over it: a task
    # cannot be listed without a branch, nor given a branch without being
    # listed, the compiler refuses both. `help` is in the registry so the
    # parser and the "unknown task" list know it, and left out of its own
    # listing. The declaration order is the order of the help.
    enum Builtin
      Version
      Licenses
      Help
      GenerateFiles
      ImageBuilder
      LintDockerfile
      Matrix
      Inspec

      # `GenerateFiles` => "generate-files".
      def task_name : String
        to_s.underscore.tr("_", "-")
      end

      def description : String
        case self
        in .version?         then "Version"
        in .licenses?        then "Print the third-party notices embedded in this binary"
        in .help?            then "Help"
        in .generate_files?  then "Generate GitlabCI matrix and Bakefile"
        in .image_builder?   then "Print the configured image builder"
        in .lint_dockerfile? then "Lint Dockerfile"
        in .matrix?          then "Print the resolved matrix as JSON"
        in .inspec?          then "Run the Inspec harness on an image"
        end
      end

      def self.for_task?(name : String) : Builtin?
        values.find { |builtin| builtin.task_name == name }
      end
    end

    # The five actions of every matrix row, with the gem's wording. The
    # description ends with the row and its archs.
    ROW_ACTIONS = {
      "build" => "Build docker image for",
      "test"  => "Test docker image for",
      "push"  => "Push docker image for",
      "clean" => "Clean docker image for",
      "login" => "Login into docker image for",
    }

    # The three actions of a row of the debuerreotype backend. It has neither
    # `test` nor `login`: the image is pushed straight from the tarballs and
    # never exists in the local docker.
    ROOTFS_ACTIONS = {
      "build" => "Build root filesystem for",
      "push"  => "Push docker image for",
      "clean" => "Clean root filesystem for",
    }

    def initialize(@stdout : IO = STDOUT, @stderr : IO = STDERR, @dir : String = Dir.current,
                   @vars : Hash(String, String) = ENV.to_h, @now : Time = Time.local,
                   @runner_factory : (Env -> Runner)? = nil)
      @task = nil.as(String?)
      @show_help = false
      @help = nil.as(String?)
      @show_version = false
      # The positional arguments of `inspec`: mode, image, then the inputs.
      @inspec_args = [] of String
    end

    def run(args : Array(String)) : Int32
      parser = build_parser
      parser.parse(args.dup)

      task = @task
      if @show_version
        @stdout.puts Donico.version_line
      elsif @show_help
        @stdout.puts(@help || parser)
      else
        # Built before the task runs, so a malformed .env fails every task
        # alike. `--help` and `--version` never read it. No task is the same
        # as `help`, which needs donico.yml: the usage text without a project
        # is what `--help` is for.
        # The environment is handed over as a block, built only by the tasks
        # that need the project: `version` and `licenses`, like `--version`,
        # must answer even when the project's files are broken.
        task ||= Builtin::Help.task_name
        return dispatch(Builtin.for_task?(task), task) { build_env }
      end
      0
    rescue e : Error
      report(e)
      1
    rescue e : IO::Error
      # stdout closed by its reader (`donico --help | head`): there is nobody
      # left to tell. Any other IO error is a bug and keeps its backtrace.
      raise e unless @stdout.closed? || e.os_error == Errno::EPIPE
      1
    end

    # The environment a task runs in: the injected variables completed by the
    # project's .env, the process variables winning. Protected so a spec can
    # observe it until a task consumes it.
    protected def build_env : Env
      Env.new(Dotenv.load(@dir, @vars), @dir, @stdout, @stderr, @now)
    end

    # The runner a task shells out through: the injected factory's, or a real
    # one. Tasks call this, never `Runner::Real.new`, so specs can substitute
    # a recording fake. Protected like `build_env`, for the same reason.
    protected def runner_for(env : Env) : Runner
      factory = @runner_factory
      factory ? factory.call(env) : Runner::Real.new(env)
    end

    private def build_parser : OptionParser
      OptionParser.new do |opts|
        opts.banner = BANNER

        Builtin.each do |builtin|
          name = builtin.task_name
          opts.on(name, builtin.description) do
            @task = name
            opts.banner = "Usage: #{NAME} #{name} [options]"
          end
        end

        opts.separator
        opts.separator "`#{NAME}` alone runs `#{NAME} help`, which lists the tasks of the project in the current directory and needs #{Config::FILE}; --help needs no project."
        opts.separator
        opts.separator "Global options:"
        opts.on("--version", "Print the version line and exit") { @show_version = true }
        # The text is taken here: the options of a task only exist in the
        # parser while it parses, they are gone once `parse` returns.
        opts.on("-h", "--help", "Print this help and exit") do
          @show_help = true
          @help = opts.to_s
        end

        opts.invalid_option { |flag| raise UsageError.new("unknown option: #{flag}") }
        opts.unknown_args do |args, after_dash|
          if @task == Builtin::Inspec.task_name
            # Inputs are `key=value` words: the ones that start with a dash
            # only reach here after `--`, so both lists belong to the task.
            @inspec_args = args + after_dash
            next
          end
          raise UsageError.new("unexpected argument: #{after_dash.first}") unless after_dash.empty?
          next if args.empty?
          first = args.first
          # With tasks declared, OptionParser routes an unknown flag given
          # before any task here rather than to `invalid_option`.
          raise UsageError.new("unknown option: #{first}") if first.starts_with?('-')
          if @task
            raise UsageError.new("unexpected argument: #{first}")
          end
          # A name that is no built-in task is kept for `dispatch`: matrix
          # tasks (<distro>:<version>:<action>) depend on donico.yml, which
          # the parser cannot read, and `dispatch` is the one place that
          # rejects a name nothing answers to.
          @task = first
          raise UsageError.new("unexpected argument: #{args[1]}") if args.size > 1
        end
      end
    end

    # Runs `task` and returns its exit code. `builtin` is the registry entry
    # `task` names, nil for a matrix task. `load_env` builds the Env, which
    # `version` and `licenses` never ask for; the tasks that need the project
    # load the config here, once.
    private def dispatch(builtin : Builtin?, task : String, & : -> Env) : Int32
      return dispatch_matrix_task(task, yield) unless builtin

      case builtin
      in .version?
        @stdout.puts VERSION
        0
      in .licenses?
        print_licenses
        0
      in .help?
        print_help(Config.load(yield))
        0
      in .generate_files?
        env = yield
        Tasks::GenerateFiles.new(Config.load(env), env).run
      in .image_builder?
        env = yield
        Tasks::ImageBuilder.new(Config.load(env), env).run
      in .matrix?
        env = yield
        Tasks::Matrix.new(Config.load(env), env).run
      in .lint_dockerfile?
        env = yield
        config = Config.load(env)
        Tasks::LintDockerfile.new(config, env, runner_for(env), ToolImages.from(config).docker_linter).run
      in .inspec?
        run_inspec(yield)
      end
    end

    # `donico inspec <mode> <image> [inputs...]`: the harness called directly,
    # on the Inspec image of the project.
    private def run_inspec(env : Env) : Int32
      mode, image = @inspec_args[0]?, @inspec_args[1]?
      if mode.nil? || image.nil?
        raise UsageError.new("usage: #{NAME} inspec <mode> <image> [inputs...] (an input starting with - goes after --)")
      end
      Inspec.check_mode!(mode)
      tools = ToolImages.from(Config.load(env))
      Inspec.new(env, runner_for(env), tools.inspec).run(mode, image, @inspec_args[2..])
    end

    # `<distro>:<version>:<action>`, split on the first and the last colon:
    # neither part can hold one (Config refuses it), so anything in between
    # that still has a colon matches no row. The config is loaded first: the
    # "unknown task" message lists the valid tasks, which depend on the matrix,
    # and a project that cannot be loaded reports that instead. A name without
    # that shape, a row or an action nothing answers to is rejected with the
    # same message, from this one place.
    private def dispatch_matrix_task(task : String, env : Env) : Int32
      config = Config.load(env)
      first = task.index(':')
      last = task.rindex(':')
      raise unknown_task(task, config) if first.nil? || last.nil? || first == last

      distro = task[0...first]
      version = task[(first + 1)...last]
      action = task[(last + 1)..]
      return dispatch_rootfs_task(task, config, env, distro, version, action) if config.debuerreotype?

      image = Image.all(config).find { |candidate| candidate.distro == distro && candidate.version == version }
      raise unknown_task(task, config) unless image

      runner = runner_for(env)
      case action
      when "build" then Tasks::Build.new(image, env, runner).run
      when "push"  then Tasks::Push.new(image, env, runner).run
      when "clean" then Tasks::Clean.new(image, env, runner).run
      when "login" then Tasks::Login.new(image, env, runner).run
      when "test"  then Tasks::Test.new(image, env, runner, ToolImages.from(config).inspec).run
      else              raise unknown_task(task, config)
      end
    end

    # The same names under the debuerreotype backend, where a row is a root
    # filesystem and has three actions.
    private def dispatch_rootfs_task(task : String, config : Config, env : Env, distro : String, version : String, action : String) : Int32
      rootfs = Rootfs.all(config).find { |candidate| candidate.distro == distro && candidate.version == version }
      raise unknown_task(task, config) unless rootfs

      runner = runner_for(env)
      case action
      when "build" then Tasks::RootfsBuild.new(rootfs, env, runner, ToolImages.from(config).debuerreotype).run
      when "push"  then Tasks::RootfsPush.new(rootfs, env, runner).run
      when "clean" then Tasks::RootfsClean.new(rootfs, env, runner).run
      else              raise unknown_task(task, config)
      end
    end

    # Every task of the project and its description: the built-ins other than
    # `help`, then the actions of each matrix row (five under bake, three
    # under debuerreotype), sorted by name.
    private def task_descriptions(config : Config) : Array({String, String})
      tasks = Builtin.values.reject(&.help?).map { |builtin| {builtin.task_name, description_of(builtin, config)} }
      actions = config.debuerreotype? ? ROOTFS_ACTIONS : ROW_ACTIONS
      config.matrix.each do |entry|
        archs = RubyList.render(entry.archs)
        actions.each do |action, wording|
          tasks << {"#{entry.task_prefix}:#{action}", "#{wording} #{entry.distro}/#{entry.version} #{archs}"}
        end
      end
      tasks.sort_by { |(name, _)| name }
    end

    # The description of a built-in in the listing of a project. It is the
    # one of `--help`, which knows no project, but for `generate-files` under
    # the debuerreotype backend, which writes no bakefile.
    private def description_of(builtin : Builtin, config : Config) : String
      return "Generate GitlabCI matrix" if builtin.generate_files? && config.debuerreotype?
      builtin.description
    end

    # The listing of the gem's `help`, with `donico` where it printed
    # `bin/rake`.
    private def print_help(config : Config) : Nil
      tasks = task_descriptions(config)
      width = tasks.max_of { |(name, _)| name.size }
      lines = tasks.map { |(name, description)| "  #{NAME} #{name.ljust(width)}  # #{description}" }
      @stdout.print "Usage:\n\n#{lines.join('\n')}\n\n"
    end

    # The one place the "unknown task" text is built: the name, then every
    # valid task, `help` included, one per line.
    private def unknown_task(task : String, config : Config) : UsageError
      names = task_descriptions(config).map { |(name, _)| name }
      names << "help"
      valid = names.sort.map { |name| "  #{name}" }
      UsageError.new("unknown task: #{task}\nValid tasks:\n#{valid.join('\n')}")
    end

    private def print_licenses : Nil
      Licenses::FILES.each_with_index do |(name, text), index|
        @stdout.puts if index > 0
        @stdout.puts "==> #{name} <=="
        @stdout.print text
      end
    end

    private def report(error : Error) : Nil
      if error.is_a?(ProblemList)
        error.problems.each { |problem| @stderr.puts "#{NAME}: #{problem}" }
      else
        @stderr.puts "#{NAME}: #{error.message}"
      end
    end
  end
end
