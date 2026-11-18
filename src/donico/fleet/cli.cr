require "../dotenv"
require "../env"
require "../error"
require "../runner"
require "../version"
require "./donico_pin"
require "./heritage"
require "./image_readme"
require "./manifest"
require "./readme"
require "./repos"
require "./sweep"
require "./versions/committer"
require "./versions/bumper"
require "./versions/github"
require "./versions/scanner"
require "./versions/screen"
require "./versions/terminal"
require "./versions/updater"
require "../config"
require "../tasks/lint_dockerfile"
require "../tool_images"

module Donico
  module Fleet
    # The name the fleet tool answers to: the same binary, installed a second
    # time under this name.
    PROGRAM = "donico-manager"

    # What opens a URL in the browser, started through `Runner#detach`.
    OPENER = {% if flag?(:darwin) %} "open" {% else %} "xdg-open" {% end %}

    # Command line of the fleet tool (`donico-manager`). Built like `Donico::CLI`
    # and for the same reason: it never calls `exit` and never touches the
    # global streams, directory, environment, clock or process starter, all
    # injected, so specs drive it in-process.
    class CLI
      # The commands of the first level. `Repos` stands for its own sub-commands.
      # The registry is this enum and `dispatch` an exhaustive `case ... in`
      # over it: a command cannot be listed without a branch.
      enum Command
        BumpDonico
        UpdateReadme
        Heritage
        Repos

        # `BumpDonico` => "bump-donico".
        def command_name : String
          to_s.underscore.tr("_", "-")
        end

        def self.for_name?(name : String) : Command?
          values.find { |command| command.command_name == name }
        end
      end

      # Where an image keeps its nonroot control, relative to the repository.
      SECURITY_SPEC = "test/default/controls/security_spec.rb"

      # The sub-commands of `repos`, same discipline as `Command`.
      enum Repo
        Update
        List
        Clone
        Status
        Diff
        Pull
        Gc
        UpdateReadme
        OpenUpstream
        CheckHadolint
        CheckSecuritySpec

        # `UpdateReadme` => "update-readme".
        def command_name : String
          to_s.underscore.tr("_", "-")
        end

        def self.for_name?(name : String) : Repo?
          values.find { |repo| repo.command_name == name }
        end
      end

      # The usage lines of section 5 of the design: the command as typed, then
      # its description. One table per level, in the order of the help.
      TOP_USAGE = [
        {"bump-donico VERSION", "Pin every image repo to a donico version"},
        {"update-readme", "Regenerate the root README from the donico.yml files"},
        {"heritage", "Regenerate the image heritage tree from the Dockerfiles"},
      ]

      REPOS_USAGE = [
        {"repos update", "Interactive TUI: bump, regenerate, commit and push image versions"},
        {"repos list", "List cloned repositories"},
        {"repos clone [REPO]", "Clone the image repositories into the workspace"},
        {"repos status [REPO]", "Run git status on the repositories"},
        {"repos diff [REPO]", "Run git diff on the repositories"},
        {"repos pull [REPO]", "Run git pull on the repositories"},
        {"repos gc [REPO]", "Run git gc on the repositories"},
        {"repos update-readme [REPO]", "Regenerate the README of each cloned image repo"},
        {"repos open-upstream [REPO]", "Open the upstream repository URLs in the browser"},
        {"repos check-hadolint [REPO]", "Run hadolint on the Dockerfiles"},
        {"repos check-security-spec", "Check that each cloned image has a security InSpec control"},
      ]

      def initialize(@stdout : IO = STDOUT, @stderr : IO = STDERR, @dir : String = Dir.current,
                     @vars : Hash(String, String) = ENV.to_h, @now : Time = Time.local,
                     @runner_factory : (Env -> Runner)? = nil,
                     @github : Versions::Github? = nil, @tty : (-> Bool)? = nil,
                     @terminal : (Versions::Screen -> Symbol)? = nil)
        @env = nil.as(Env?)
      end

      def run(args : Array(String)) : Int32
        first = args.first?
        if first.nil? || args.any? { |arg| arg == "--help" || arg == "-h" }
          return first == "repos" ? usage("repos <command>", REPOS_USAGE) : usage("<command>", TOP_USAGE + REPOS_USAGE)
        end
        if first == "--version"
          @stdout.puts "#{PROGRAM} #{Donico.version}"
          return 0
        end
        raise UsageError.new("unknown option: #{first}") if first.starts_with?('-')

        command = Command.for_name?(first) || raise unknown_command(first, TOP_USAGE + REPOS_USAGE)
        dispatch(command, args)
      rescue e : Error
        @stderr.puts "#{PROGRAM}: #{e.message}"
        1
      rescue e : IO::Error
        # stdout closed by its reader: there is nobody left to tell. Any other
        # IO error is a bug and keeps its backtrace.
        raise e unless @stdout.closed? || e.os_error == Errno::EPIPE
        1
      end

      # The environment a command runs in: the injected variables completed by
      # the `.env` of the configuration repository, the process variables
      # winning. Built once, by the first command that needs it; `--help` and
      # `--version` never read the file.
      protected def env : Env
        @env ||= Env.new(Dotenv.load(@dir, @vars), @dir, @stdout, @stderr, @now)
      end

      # The runner of one repository: the injected factory's, or a real one.
      # Its `Env` points at `dir`, carries the fleet's variables plus
      # DONICO_QUIET (the processes of a fleet command are not announced: the
      # `run_cmd:` lines would write over the text interface) and the fleet's
      # streams.
      protected def runner_for(dir : String) : Runner
        quiet = Env.new(env.vars.merge({"DONICO_QUIET" => "1"}), dir, @stdout, @stderr, @now)
        factory = @runner_factory
        factory ? factory.call(quiet) : Runner::Real.new(quiet)
      end

      # `args` is the whole command line after the program name, the command first.
      private def dispatch(command : Command, args : Array(String)) : Int32
        case command
        in .bump_donico?
          bump_donico(args)
        in .update_readme?
          arguments(args, 0)
          Readme.new(fleet_repos, env).run
          0
        in .heritage?
          arguments(args, 0)
          Heritage.new(fleet_repos, env).run
          0
        in .repos?
          dispatch_repos(args[1..])
        end
      end

      private def dispatch_repos(args : Array(String)) : Int32
        first = args.first?
        return usage("repos <command>", REPOS_USAGE) if first.nil?
        raise UsageError.new("unknown option: #{first}") if first.starts_with?('-')

        repo = Repo.for_name?(first) || raise unknown_command(first, REPOS_USAGE)
        case repo
        in .list?
          arguments(args, 0)
          list
        in .clone?
          clone(arguments(args, 1).first?)
        in .status?
          sweep("status", arguments(args, 1).first?)
        in .diff?
          sweep("diff", arguments(args, 1).first?)
        in .pull?
          sweep("pull", arguments(args, 1).first?)
        in .gc?
          sweep("gc", arguments(args, 1).first?)
        in .check_security_spec?
          arguments(args, 0)
          check_security_spec
        in .update_readme?
          ImageReadme.new(fleet_repos, env).run(arguments(args, 1).first?)
          0
        in .update?
          arguments(args, 0)
          update
        in .open_upstream?
          open_upstream(arguments(args, 1).first?)
        in .check_hadolint?
          check_hadolint(arguments(args, 1).first?)
        end
      end

      # `repos update`: the text interface over the whole update (scan, select,
      # apply, push). Nothing is printed before or after it, nor during: the
      # README generators of the apply phase narrate on a stream thrown away,
      # and every process is quiet and captured. A rate limit reached during
      # the scan leaves the interface (the terminal restored) as its message.
      private def update : Int32
        token = env.vars["GITHUB_TOKEN"]?
        if token.nil? || token.empty?
          raise Error.new("GITHUB_TOKEN is not set. The anonymous GitHub limit (60 requests/hour) cannot cover a full scan. Export a token and retry.")
        end
        raise Error.new("`repos update` needs an interactive terminal.") unless (@tty || ->CLI.controlling_terminal?).call

        terminal = @terminal || ->(screen : Versions::Screen) { Versions::Terminal.new(screen).run }
        terminal.call(update_screen(token))
        0
      rescue error : Versions::Terminal::Interrupted
        # SIGTERM or SIGHUP: the terminal is back, 128 + the signal number.
        128 + error.signal.value
      end

      private def update_screen(token : String) : Versions::Screen
        repos = fleet_repos
        silent = Env.new(env.vars, env.dir, IO::Memory.new, IO::Memory.new, @now)
        runner_for = ->(dir : String) { runner_for(dir) }
        readmes = -> : Nil do
          ImageReadme.new(repos, silent).run
          Readme.new(repos, silent).run
        end
        updater = Versions::Updater.new(
          Versions::Scanner.new(repos, @github || Versions::Github.new(token, vars: env.vars)),
          Versions::Bumper.new(repos, silent, runner_for),
          Versions::Committer.new(repos, silent, runner_for),
          readmes)
        Versions::Screen.new(updater, ->(row : Versions::Row) { open_url(row.url) })
      end

      # Opens `url` in the browser, from the configuration repository. The
      # opener is detached: it would otherwise write over the text interface,
      # or keep a pipe open for as long as the browser runs.
      private def open_url(url : String) : Nil
        runner_for(env.dir).detach(OPENER, [url])
      end

      # True when the process has a controlling terminal, the one the text
      # interface opens (`/dev/tty`), whatever its standard streams are.
      def self.controlling_terminal? : Bool
        File.open("/dev/tty", "r+") { true }
      rescue File::Error
        false
      end

      # `bump-donico VERSION [--push]`: pins every image repository to the donico
      # version of this binary, regenerates its files and commits them. One
      # repository's failure does not stop the others.
      #
      # VERSION must be the running binary's: the files are regenerated by it, so
      # another number would pin one version and commit the output of another.
      private def bump_donico(args : Array(String)) : Int32
        push, version = bump_arguments(args)
        raise UsageError.new("Expected a version like #{Donico::VERSION}, got #{version}") unless version.matches?(/\A\d+(\.\d+)*\z/)
        unless version == Donico::VERSION
          raise UsageError.new("bump-donico #{version}: this binary is donico #{Donico::VERSION}, and the files it regenerates would be its own")
        end

        repos = fleet_repos
        pin = DonicoPin.new(repos, env, ->(dir : String) { runner_for(dir) })
        committer = Versions::Committer.new(repos, env, ->(dir : String) { runner_for(dir) })
        failed = repos.all.count { |name| !bump_one(name, version, push, pin, committer) }

        @stdout.puts
        @stdout.puts failed.zero? ? paint("Done.", :green) : paint("#{failed} repository/repositories failed.", :red)
        failed.zero? ? 0 : 1
      end

      # {push, version}: `--push` is the one option, anywhere on the line; an
      # unknown option is refused first, then a missing VERSION, then a surplus
      # argument.
      private def bump_arguments(args : Array(String)) : {Bool, String}
        rest = args[1..]
        option = rest.find { |arg| arg.starts_with?('-') && arg != "--push" }
        raise UsageError.new("unknown option: #{option}") if option

        positional = rest.reject { |arg| arg == "--push" }
        raise UsageError.new("missing argument: VERSION") if positional.empty?
        raise UsageError.new("unexpected argument: #{positional[1]}") if positional.size > 1

        {rest.includes?("--push"), positional.first}
      end

      # One repository: its line, then its commit and push. A skip is a normal
      # outcome (a repository that is excluded, not cloned, or not migrated yet),
      # not a failure. A refused commit is reported and fails the repository,
      # where the gem dropped that result; a refused push is reported and, as in
      # the gem, does not change the status.
      private def bump_one(name : String, version : String, push : Bool, pin : DonicoPin, committer : Versions::Committer) : Bool
        status, message = pin.call(name, version)
        case status
        when :skip
          @stdout.puts "  = #{message}"
          true
        when :fail
          @stdout.puts paint("  ! #{name}: #{message}", :red)
          false
        else
          @stdout.puts paint("  + #{name}", :green)
          commit_and_push(name, version, push, committer)
        end
      end

      private def commit_and_push(name : String, version : String, push : Bool, committer : Versions::Committer) : Bool
        status, message = committer.commit_donico(name, version)
        if status == :fail
          @stdout.puts paint("  ! #{name}: commit failed: #{message}", :red)
          return false
        end
        return true unless push

        status, message = committer.push(name)
        @stdout.puts paint("  ! #{name}: push failed: #{message}", :red) if status == :fail
        true
      end

      # The positional arguments after a command, at most `max` of them: an
      # option is refused first (none is known), then a surplus argument.
      private def arguments(args : Array(String), max : Int32) : Array(String)
        rest = args[1..]
        option = rest.find(&.starts_with?('-'))
        raise UsageError.new("unknown option: #{option}") if option
        raise UsageError.new("unexpected argument: #{rest[max]}") if rest.size > max
        rest
      end

      private def fleet_repos : Repos
        Repos.new(Manifest.load(env), env.dir)
      end

      # `git <command>` in each cloned repository, on the terminal's streams.
      private def sweep(command : String, name : String?) : Int32
        failed = Sweep.new(fleet_repos, env, ->(dir : String) { runner_for(dir) }).call(name) do |_name, runner|
          runner.system("git", [command]) == 0
        end
        report_failures(failed)
      end

      # The last line of a sweep: how many repositories failed, and the status.
      # It is the end of a report, not an error, so it goes to stdout without
      # the program prefix.
      private def report_failures(failed : Int32) : Int32
        return 0 if failed.zero?

        @stdout.puts paint("#{failed} repository/repositories failed.", :red)
        1
      end

      # A line of the fleet's own in its colour, on the terminal only and as the
      # fleet's variables allow (NO_COLOR, TERM).
      private def paint(text : String, color : Symbol) : String
        Color.paint(@stdout, text, color, env.vars)
      end

      private def list : Int32
        repos = fleet_repos
        repos.all.each do |name|
          cloned = repos.cloned?(name)
          @stdout.puts "#{cloned ? "Repository exists" : "Repository missing"}: #{paint(name, cloned ? :green : :red)}"
        end
        0
      end

      # Counts the clones that failed, like every other sweep: git writes its own
      # diagnostic, but the exit status is what a provisioning job reads.
      private def clone(name : String?) : Int32
        repos = fleet_repos
        names = repos.resolve(name)
        Dir.mkdir_p(repos.workspace)
        runner = runner_for(env.dir)
        failed = names.count { |image| !clone_one(repos, runner, image) }
        report_failures(failed)
      end

      # Clones one repository, or reports it as already there: that is a normal
      # outcome, not a failure.
      private def clone_one(repos : Repos, runner : Runner, name : String) : Bool
        if repos.cloned?(name)
          @stdout.puts "#{name}: already cloned, skipping"
          return true
        end

        @stdout.puts "Cloning #{name}"
        runner.system("git", ["clone", repos.clone_url(name), repos.path(name)]) == 0
      end

      # `repos open-upstream [REPO]`: opens the upstream URL of each image, the
      # parenthesised link of a README line that mentions "upstream". As in the
      # gem, without REPO every README of the workspace is read, declared or
      # not; each URL is opened once.
      private def open_upstream(name : String?) : Int32
        urls = upstream_urls(name)
        if urls.empty?
          @stdout.puts "No upstream URL found in the cloned READMEs."
          return 0
        end

        urls.each { |url| open_url(url) }
        0
      end

      private def upstream_urls(name : String?) : Array(String)
        repos = fleet_repos
        images = name ? repos.resolve(name) : workspace_entries(repos.workspace)
        paths = images.map { |image| File.join(repos.path(image), "README.md") }.select { |path| File.file?(path) }
        paths.flat_map do |path|
          File.read_lines(path).select(&.matches?(/upstream/i)).compact_map { |line| line[/\((https?:[^)]+)\)/, 1]? }
        end.uniq!
      end

      # What Ruby's `Dir.glob("<workspace>/*")` lists: the entries not starting
      # with a dot, sorted by name, so the URLs open in the gem's order.
      private def workspace_entries(workspace : String) : Array(String)
        return [] of String unless Dir.exists?(workspace)

        Dir.children(workspace).reject(&.starts_with?('.')).sort!
      end

      # `repos check-hadolint [REPO]`: the `lint-dockerfile` task of each
      # cloned repository, in process, inside the sweep's lines. Unlike the
      # other fleet commands, the lines the task and its processes print are
      # kept: they are the report. Each repository is its own project: its
      # `.env` completes the fleet's variables and its `donico.yml` names the
      # linter image. A repository donico refuses is that repository's
      # failure, with donico's message, and the sweep goes on.
      private def check_hadolint(name : String?) : Int32
        envs = {} of String => Env | Error
        runner_of = ->(dir : String) do
          prepared = lint_env(dir)
          envs[dir] = prepared
          # A refused .env fails the repository before any process starts:
          # the runner is then built on the fleet's variables and never used.
          lint_runner(prepared.as?(Env) || Env.new(env.vars, dir, @stdout, @stderr, @now))
        end
        repos = fleet_repos
        failed = Sweep.new(repos, env, runner_of).call(name) do |image, runner|
          lint(envs[repos.path(image)], runner)
        end
        report_failures(failed)
      end

      # The environment of the repository at `dir`, as `donico` builds it
      # there, or the error that refuses it.
      private def lint_env(dir : String) : Env | Error
        Env.new(Dotenv.load(dir, env.vars), dir, @stdout, @stderr, @now)
      rescue error : Error
        error
      end

      # Not quiet: the lint is the one fleet command whose processes are
      # announced, like `donico lint-dockerfile` announces them.
      private def lint_runner(repo_env : Env) : Runner
        factory = @runner_factory
        factory ? factory.call(repo_env) : Runner::Real.new(repo_env)
      end

      private def lint(prepared : Env | Error, runner : Runner) : Bool
        raise prepared if prepared.is_a?(Error)

        config = Config.load(prepared)
        Tasks::LintDockerfile.new(config, prepared, runner, ToolImages.from(config).docker_linter).run == 0
      rescue error : Error
        @stderr.puts "#{PROGRAM}: #{error.message}"
        false
      end

      # Every image is meant to ship an InSpec control asserting that it runs as
      # nonroot. Only cloned images are looked at: one that is not cloned has no
      # file to read.
      private def check_security_spec : Int32
        repos = fleet_repos
        names = repos.cloned
        if names.empty?
          @stdout.puts "No cloned repository."
          return 0
        end

        missing = names.reject { |name| File.file?(File.join(repos.path(name), SECURITY_SPEC)) }
        names.each do |name|
          ok = !missing.includes?(name)
          @stdout.puts "#{ok ? "OK" : "MISSING"}: #{paint(name, ok ? :green : :red)}"
        end
        missing.empty? ? 0 : 1
      end

      private def usage(title : String, lines : Array({String, String})) : Int32
        @stdout.puts "Usage: #{PROGRAM} #{title} [options]"
        @stdout.puts render(lines)
        0
      end

      private def unknown_command(name : String, lines : Array({String, String})) : UsageError
        UsageError.new("unknown command: #{name}\n#{render(lines)}")
      end

      # One line per command, the descriptions in a column.
      private def render(lines : Array({String, String})) : String
        width = (TOP_USAGE + REPOS_USAGE).max_of { |(command, _)| command.size }
        lines.map { |(command, description)| "#{PROGRAM} #{command.ljust(width)}  # #{description}" }.join('\n')
      end
    end
  end

  # True when `name`, as the program was invoked (argv[0], a bare name or a
  # path), is the fleet tool's: the binary is the same under both names.
  def self.fleet_program?(name : String) : Bool
    File.basename(name) == Fleet::PROGRAM
  end
end
