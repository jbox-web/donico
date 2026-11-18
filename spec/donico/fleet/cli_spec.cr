require "../../spec_helper"

# The fourteen commands of the design (section 5), with their descriptions, in
# order: the text `--help` and the "unknown command" list must print.
TOP_LINES = [
  "donico-manager bump-donico VERSION          # Pin every image repo to a donico version",
  "donico-manager update-readme                # Regenerate the root README from the donico.yml files",
  "donico-manager heritage                     # Regenerate the image heritage tree from the Dockerfiles",
]

REPOS_LINES = [
  "donico-manager repos update                 # Interactive TUI: bump, regenerate, commit and push image versions",
  "donico-manager repos list                   # List cloned repositories",
  "donico-manager repos clone [REPO]           # Clone the image repositories into the workspace",
  "donico-manager repos status [REPO]          # Run git status on the repositories",
  "donico-manager repos diff [REPO]            # Run git diff on the repositories",
  "donico-manager repos pull [REPO]            # Run git pull on the repositories",
  "donico-manager repos gc [REPO]              # Run git gc on the repositories",
  "donico-manager repos update-readme [REPO]   # Regenerate the README of each cloned image repo",
  "donico-manager repos open-upstream [REPO]   # Open the upstream repository URLs in the browser",
  "donico-manager repos check-hadolint [REPO]  # Run hadolint on the Dockerfiles",
  "donico-manager repos check-security-spec    # Check that each cloned image has a security InSpec control",
]

# Exposes what the fleet command line builds for the commands to come.
class FleetProbeCLI < Donico::Fleet::CLI
  def probe : Donico::Env
    env
  end

  def probe_runner(dir : String) : Donico::Runner
    runner_for(dir)
  end
end

describe "Donico.fleet_program?" do
  it "is true when the basename is donico-manager" do
    ["donico-manager", "/usr/bin/donico-manager", "./bin/donico-manager"].each do |name|
      Donico.fleet_program?(name).should be_true
    end
  end

  it "is false for any other name" do
    ["donico", "donico-manager.old", "/usr/bin/donico"].each do |name|
      Donico.fleet_program?(name).should be_false
    end
  end
end

describe Donico::Fleet::CLI do
  it "names the program donico-manager" do
    Donico::Fleet::PROGRAM.should eq "donico-manager"
  end

  describe "usage" do
    usage = (["Usage: donico-manager <command> [options]"] + TOP_LINES + REPOS_LINES).join('\n') + "\n"
    repos_usage = (["Usage: donico-manager repos <command> [options]"] + REPOS_LINES).join('\n') + "\n"

    it "is printed with no argument, --help and -h" do
      with_tmp_dir do |dir|
        [[] of String, ["--help"], ["-h"]].each do |args|
          run = run_fleet_in(dir, args)

          run.code.should eq 0
          run.stdout.should eq usage
          run.stderr.should be_empty
        end
      end
    end

    it "lists the eleven repos lines for repos --help" do
      with_tmp_dir do |dir|
        run = run_fleet_in(dir, ["repos", "--help"])

        run.code.should eq 0
        run.stdout.should eq repos_usage
        run.stdout.lines.size.should eq 12
      end
    end

    describe "--help or -h after the first argument" do
      it "prints the eleven repos lines when the first argument is repos" do
        with_tmp_dir do |dir|
          [["repos", "status", "--help"], ["repos", "update-readme", "ruby", "-h"], ["repos", "nope", "--help"]].each do |args|
            run = run_fleet_in(dir, args)

            run.code.should eq 0
            run.stdout.should eq repos_usage
            run.stderr.should be_empty
          end
        end
      end

      it "prints the full usage under any other first argument" do
        with_tmp_dir do |dir|
          [["update-readme", "--help"], ["bump-donico", "3.1.0", "-h"], ["nope", "--help"]].each do |args|
            run = run_fleet_in(dir, args)

            run.code.should eq 0
            run.stdout.should eq usage
            run.stderr.should be_empty
          end
        end
      end
    end
  end

  describe "--version" do
    it "prints the program name and the version" do
      with_tmp_dir do |dir|
        run = run_fleet_in(dir, ["--version"])

        run.code.should eq 0
        run.stdout.should start_with "donico-manager #{Donico::VERSION} ("
        run.stdout.should end_with ")\n"
        run.stderr.should be_empty
      end
    end
  end

  describe "an unknown command" do
    it "is reported with the fourteen commands" do
      with_tmp_dir do |dir|
        run = run_fleet_in(dir, ["nope"])

        run.code.should eq 1
        run.stdout.should be_empty
        run.stderr.should eq((["donico-manager: unknown command: nope"] + TOP_LINES + REPOS_LINES).join('\n') + "\n")
      end
    end

    it "is reported with the eleven repos lines for a repos subcommand" do
      with_tmp_dir do |dir|
        run = run_fleet_in(dir, ["repos", "nope"])

        run.code.should eq 1
        run.stdout.should be_empty
        run.stderr.should eq((["donico-manager: unknown command: nope"] + REPOS_LINES).join('\n') + "\n")
      end
    end
  end

  describe "an unknown option" do
    it "is reported on stderr" do
      with_tmp_dir do |dir|
        run = run_fleet_in(dir, ["--nope"])

        run.code.should eq 1
        run.stderr.should eq "donico-manager: unknown option: --nope\n"
        run.stdout.should be_empty
      end
    end
  end

  describe "environment" do
    it "completes the injected variables with the .env of the configuration repository, injected ones winning" do
      with_tmp_dir do |dir|
        File.write(File.join(dir, ".env"), "A=from-file\nB=2\n")
        cli = FleetProbeCLI.new(IO::Memory.new, IO::Memory.new, dir, {"A" => "from-env"})

        env = cli.probe
        env.vars.should eq({"A" => "from-env", "B" => "2"})
        env.dir.should eq dir
      end
    end

    it "reports a malformed .env as one line, without the content of the line" do
      with_tmp_dir do |dir|
        File.write(File.join(dir, ".env"), "A=1\njust words\n")
        run = run_fleet_in(dir, ["heritage"])

        run.code.should eq 1
        run.stderr.should eq "donico-manager: .env: line 2 is not KEY=VALUE\n"
        run.stdout.should be_empty
      end
    end

    it "does not read .env for --help and --version" do
      with_tmp_dir do |dir|
        File.write(File.join(dir, ".env"), "just words\n")

        ["--help", "--version"].each do |arg|
          run_fleet_in(dir, [arg]).code.should eq 0
        end
      end
    end
  end

  describe "the runner of a repository" do
    it "is built on that repository, with the fleet's variables plus DONICO_QUIET and its streams" do
      with_tmp_dir do |dir|
        seen = [] of Donico::Env
        runner = RecordingRunner.new
        factory = ->(env : Donico::Env) { seen << env; runner.as(Donico::Runner) }
        stdout = IO::Memory.new
        stderr = IO::Memory.new
        cli = FleetProbeCLI.new(stdout, stderr, dir, {"A" => "1"}, Time.utc(2026, 7, 31), factory)

        cli.probe_runner("/some/repo").should be runner
        seen.size.should eq 1
        seen[0].dir.should eq "/some/repo"
        seen[0].vars.should eq({"A" => "1", "DONICO_QUIET" => "1"})
        seen[0].stdout.should be stdout
        seen[0].stderr.should be stderr
      end
    end
  end

  describe "an error raised by a command" do
    it "is one line prefixed with the program name" do
      with_tmp_dir do |dir|
        run = run_fleet_in(dir, ["repos", "open-upstream"])

        run.code.should eq 1
        run.stderr.should eq "donico-manager: donico-manager.yml not found. donico-manager runs from the root of a fleet's configuration repository.\n"
        run.stdout.should be_empty
      end
    end
  end

  describe "a reader that closed the pipe" do
    it "ends with status 1 and prints nothing more" do
      with_tmp_dir do |dir|
        stdout = IO::Memory.new
        stdout.close
        stderr = IO::Memory.new

        Donico::Fleet::CLI.new(stdout, stderr, dir).run(["--help"]).should eq 1
        stderr.to_s.should be_empty
      end
    end
  end
end
