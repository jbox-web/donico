require "../env"
require "../runner"
require "./repos"

module Donico
  module Fleet
    # Colours of the fleet's own lines: the gem's (Thor's `set_color`), only on
    # a terminal so that a pipe or a file gets plain text. Thor also leaves
    # them out when NO_COLOR holds a value (https://no-color.org) or TERM is
    # `dumb`; `vars` are the fleet's variables (`Env#vars`), never the
    # process's own ENV.
    module Color
      def self.paint(io : IO, text : String, color : Symbol, vars : Hash(String, String)) : String
        return text unless io.tty?
        return text if vars["TERM"]? == "dumb"
        return text unless vars["NO_COLOR"]?.to_s.empty?

        code = case color
               when :red   then 31
               when :green then 32
               else
                 raise ArgumentError.new("unknown colour: #{color}")
               end
        "\e[#{code}m#{text}\e[0m"
      end
    end

    # Runs one command in each cloned image repository, announcing the repository
    # it enters and skipping the ones that are not cloned. A failure never stops
    # the sweep: one broken repository must not hide the state of the others.
    class Sweep
      SEPARATOR = "---------------------"

      # `runner_for` receives the directory of a repository and answers the
      # runner that works there; it is asked for a cloned repository only.
      def initialize(@repos : Repos, @env : Env, @runner_for : String -> Runner)
      end

      # The number of repositories whose block returned false. The block gets
      # the name and the runner of the repository.
      def call(repo : String?, & : String, Runner -> Bool) : Int32
        @repos.resolve(repo).count { |name| !run_in(name) { |runner| yield name, runner } }
      end

      private def run_in(name : String, & : Runner -> Bool) : Bool
        unless @repos.cloned?(name)
          @env.stdout.puts "#{name}: not cloned, skipping"
          # A partially cloned workspace is normal, not a failure.
          return true
        end

        @env.stdout.puts SEPARATOR
        @env.stdout.puts "Enter in #{name}"
        ok = yield @runner_for.call(@repos.path(name))
        @env.stdout.puts SEPARATOR
        @env.stdout.puts
        ok
      end
    end
  end
end
