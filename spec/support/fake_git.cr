require "../../src/donico/runner"

# A fake `git` for the fleet units: starts nothing, records every call with the
# directory it was made in, and answers by the repository (the directory's
# basename) and a fragment of the command line. Unscripted answers are those of
# a clean repository on master with a change staged. `RecordingRunner` answers
# by order of call, which cannot say "the second repository is dirty".
class FakeGit
  record Call, dir : String, command : String, args : Array(String) do
    def line : String
      ([command] + args).join(' ')
    end
  end

  record Answer, repo : String?, fragment : String, code : Int32, text : String

  getter calls = [] of Call

  def initialize
    @answers = [] of Answer
    @lock = Mutex.new
  end

  # `repo` nil answers for every repository.
  def answer(fragment : String, code : Int32 = 0, text : String = "", repo : String? = nil) : self
    @answers << Answer.new(repo, fragment, code, text)
    self
  end

  # The calls whose command line contains `fragment`, in order.
  def lines(fragment : String = "") : Array(String)
    calls.map(&.line).select(&.includes?(fragment))
  end

  # The directories git was called in, each once, in order of first call.
  def dirs : Array(String)
    calls.map(&.dir).uniq!
  end

  def calls_in(repo : String) : Array(Call)
    calls.select { |call| File.basename(call.dir) == repo }
  end

  def runner_for(dir : String) : Donico::Runner
    Runner.new(self, dir)
  end

  # The `runner_for` the fleet units are given.
  def for_dir : String -> Donico::Runner
    ->(dir : String) : Donico::Runner { runner_for(dir) }
  end

  def factory : Donico::Env -> Donico::Runner
    ->(env : Donico::Env) : Donico::Runner { runner_for(env.dir) }
  end

  def respond(dir : String, command : String, args : Array(String)) : {Int32, String}
    call = Call.new(dir, command, args)
    @lock.synchronize { @calls << call }
    line = call.line
    scripted = @answers.find do |answer|
      line.includes?(answer.fragment) && (answer.repo.nil? || answer.repo == File.basename(dir))
    end
    return {scripted.code, scripted.text} if scripted
    return {0, "master\n"} if line.includes?("rev-parse")
    return {1, ""} if line.includes?("diff --cached")

    {0, ""}
  end

  class Runner < Donico::Runner
    def initialize(@git : FakeGit, @dir : String)
    end

    def exec(command : String, args : Array(String), env : Vars = Vars.new) : Int32
      @git.respond(@dir, command, args)[0]
    end

    def system(command : String, args : Array(String), env : Vars = Vars.new) : Int32
      @git.respond(@dir, command, args)[0]
    end

    def capture(command : String, args : Array(String), env : Vars = Vars.new) : {Int32, String}
      @git.respond(@dir, command, args)
    end

    def output(command : String, args : Array(String), env : Vars = Vars.new) : {Int32, String}
      @git.respond(@dir, command, args)
    end

    # Recorded like the other calls: the fleet's opener goes through it.
    def detach(command : String, args : Array(String)) : Nil
      @git.respond(@dir, command, args)
    end

    def forward(signal : Signal) : Nil
    end
  end
end
