module Donico
  # Root of every error donico raises on purpose. The CLI rescues this class
  # alone: it prints the message and exits 1. Anything else escaping is a bug
  # and keeps its backtrace.
  class Error < Exception
  end

  # Wrong command line: unknown task or option.
  class UsageError < Error
  end

  # A donico.yml or .env that cannot be loaded or does not validate.
  class ConfigError < Error
  end

  # The surroundings are not what a task needs: a missing executable, an
  # unset secret variable, a secret file that does not exist.
  class EnvironmentError < Error
  end

  # Several independent problems of the same kind, reported together. Unlike
  # a message with a list under a heading (the "unknown task" listing), each
  # problem stands alone, so the CLI prefixes every one of them.
  class ProblemList < EnvironmentError
    getter problems : Array(String)

    def initialize(@problems : Array(String))
      super(@problems.join("\n"))
    end
  end
end
