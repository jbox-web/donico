require "./recording_runner"

# A recording runner that fails on demand: the Inspec call raises "inspec
# failed", the cleanup call (docker kill) raises "cleanup failed". Each call is
# recorded before it raises.
class FailingRunner < RecordingRunner
  property? fail_start = false
  property? fail_inspec = false
  property? fail_cleanup = false

  # The start raises the way the real runner does when docker is missing.
  def output(command : String, args : Array(String), env : Vars = Vars.new) : {Int32, String}
    result = super
    raise Donico::EnvironmentError.new("start failed") if fail_start?
    result
  end

  def system(command : String, args : Array(String), env : Vars = Vars.new) : Int32
    code = super
    raise Donico::EnvironmentError.new("inspec failed") if fail_inspec? && args.includes?("inspec")
    raise Donico::EnvironmentError.new("cleanup failed") if fail_cleanup? && args.first? == "kill"
    code
  end
end

# A recording runner that delivers a signal to the harness at a chosen moment,
# as the signal handler would, then returns the scripted code: after the
# Inspec call by default, after the start with `signal_on_output`, or during
# the cleanup call with `signal_on_cleanup`.
class SignallingRunner < RecordingRunner
  property harness : Donico::Inspec?
  property signal : Signal = Signal::INT
  property? signal_on_output = false
  property? signal_on_cleanup = false

  def output(command : String, args : Array(String), env : Vars = Vars.new) : {Int32, String}
    result = super
    harness.try(&.handle_signal(signal)) if signal_on_output?
    result
  end

  def system(command : String, args : Array(String), env : Vars = Vars.new) : Int32
    code = super
    # In `signal_on_cleanup` mode the signal comes only during the cleanup.
    during_run = args.includes?("inspec") && !signal_on_cleanup?
    during_cleanup = signal_on_cleanup? && args.first? == "kill"
    harness.try(&.handle_signal(signal)) if during_run || during_cleanup
    code
  end
end
