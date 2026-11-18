# A program for the pseudo-terminal specs (spec/donico/fleet/versions/
# terminal_spec.cr), compiled by them: the real `Terminal` and `Screen` over
# the real `Updater`, whose scanner, bumper and committer are fakes. The
# compiled binary cannot reach an apply phase without GitHub; this one can,
# and can be made to fail in it. Never required by the specs (it has
# top-level code).
#
#   screen_harness held           the scan never ends
#   screen_harness bump-raises    two updates; their bump raises
#   screen_harness readmes-raise  two updates; the README generators raise
#   screen_harness config-fails   two updates; the root README commit is
#                                 refused with git's two-line message
#
# Prints `outcome: <outcome>` once the interface has given the terminal back.
require "../../src/donico/fleet/versions/terminal"
require "../../src/donico/fleet/versions/updater"

module ScreenHarness
  alias Versions = Donico::Fleet::Versions

  def self.row(image : String) : Versions::Row
    Versions::Row.new(image: image, current: "1.0.0", latest: "1.0.1", state: Versions::State::Update,
      repo: "org/#{image}", quoted: false)
  end

  class Scanner
    def initialize(@held : Bool)
    end

    def call(& : Int32, Int32 ->) : Array(Versions::Row)
      yield 1, 3
      while @held
        sleep 1.second
      end
      [ScreenHarness.row("alpha"), ScreenHarness.row("bravo")]
    end
  end

  class Bumper
    def initialize(@raises : Bool)
    end

    def call(row : Versions::Row) : Donico::Fleet::Outcome
      raise "bump of #{row.image} exploded" if @raises
      {:ok, nil}
    end
  end

  # What git prints when a hook refuses the commit: two lines, the second
  # wider than the 120 columns of the specs' terminal.
  CONFIG_REFUSAL = "To example.org:fleet/config.git\n ! [remote rejected] master -> master " \
                   "(pre-receive hook declined: the commit message does not follow the convention " \
                   "of this repository, see CONTRIBUTING.md)"

  class Committer
    def initialize(@config_fails : Bool)
    end

    def commit_image(row : Versions::Row) : Donico::Fleet::Outcome
      {:ok, nil}
    end

    def commit_config(rows : Array(Versions::Row)) : Donico::Fleet::Outcome
      @config_fails ? {:fail, CONFIG_REFUSAL} : {:ok, nil}
    end

    def push(image : String?) : Donico::Fleet::Outcome
      {:ok, nil}
    end
  end
end

mode = ARGV[0]? || ""
readmes = -> : Nil do
  raise "README generator exploded" if mode == "readmes-raise"
end
updater = Donico::Fleet::Versions::Updater.new(ScreenHarness::Scanner.new(mode == "held"),
  ScreenHarness::Bumper.new(mode == "bump-raises"), ScreenHarness::Committer.new(mode == "config-fails"), readmes)
screen = Donico::Fleet::Versions::Screen.new(updater, ->(_row : Donico::Fleet::Versions::Row) { nil })
begin
  outcome = Donico::Fleet::Versions::Terminal.new(screen).run
  puts "outcome: #{outcome}"
rescue error : Donico::Fleet::Versions::Terminal::Interrupted
  # As the command line does: 128 + the signal number.
  exit 128 + error.signal.value
end
