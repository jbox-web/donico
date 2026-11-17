module Donico
  # What a task runs in. `vars` is the process environment completed by the
  # project's .env; `dir` is the project directory; the streams and the clock
  # are injected so that specs drive a task without touching the process.
  record Env, vars : Hash(String, String), dir : String, stdout : IO, stderr : IO, now : Time
end
