require "../../src/donico/runner"

# A fake Runner for task specs: it starts nothing, records every call and
# answers from a queue of scripted results. With the queue empty it answers
# success with an empty text, so a spec scripts only the calls it cares about.
class RecordingRunner < Donico::Runner
  record Call, kind : Symbol, command : String, args : Array(String), env : Hash(String, String)
  record Result, code : Int32, text : String

  def initialize
    @calls = [] of Call
    @results = [] of Result
    # `forward` is called from a signal fiber while a task runs, possibly on
    # another thread under -Dpreview_mt.
    @lock = Mutex.new
  end

  # A snapshot, so a reader never iterates the array while it grows.
  def calls : Array(Call)
    @lock.synchronize { @calls.dup }
  end

  # Queues the answer of the next call that returns a status (every kind but
  # `forward` and `detach`, which answer nothing: a scripted result is not
  # consumed by them).
  def script(code : Int32 = 0, text : String = "") : self
    @lock.synchronize { @results << Result.new(code, text) }
    self
  end

  def exec(command : String, args : Array(String), env : Vars = Vars.new) : Int32
    next_result(:exec, command, args, env).code
  end

  def system(command : String, args : Array(String), env : Vars = Vars.new) : Int32
    next_result(:system, command, args, env).code
  end

  def capture(command : String, args : Array(String), env : Vars = Vars.new) : {Int32, String}
    result = next_result(:capture, command, args, env)
    {result.code, result.text}
  end

  def output(command : String, args : Array(String), env : Vars = Vars.new) : {Int32, String}
    result = next_result(:output, command, args, env)
    {result.code, result.text}
  end

  def detach(command : String, args : Array(String)) : Nil
    @lock.synchronize { @calls << Call.new(:detach, command, args, Vars.new) }
  end

  def forward(signal : Signal) : Nil
    @lock.synchronize { @calls << Call.new(:forward, signal.to_s, [] of String, Vars.new) }
  end

  private def next_result(kind : Symbol, command : String, args : Array(String), env : Vars) : Result
    @lock.synchronize do
      @calls << Call.new(kind, command, args, env)
      @results.shift? || Result.new(0, "")
    end
  end
end
