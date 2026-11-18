require "../config"
require "../dotenv"
require "../env"
require "../error"
require "../tasks/generate_files"

module Donico
  module Fleet
    # The result of one step on one repository, the gem's `[status, message]`:
    # `:ok`, `:skip` (nothing to do, not a failure) or `:fail`.
    alias Outcome = {Symbol, String?}

    # Regenerates `docker-bake.hcl` and the CI matrix of one image repository
    # with the running binary: the `generate-files` task, in process. The gem
    # ran the repository's own `bin/rake generate-files`; the binary has no
    # business starting another donico.
    module Regenerate
      # `env_of_repo` is the repository's: its `dir` is the repository and its
      # `vars` are completed by its `.env`. Nothing reaches its streams: the
      # task announces its files on a stream of its own, thrown away, since a
      # fleet command writes its own lines (and the text interface owns the
      # terminal).
      def self.call(env_of_repo : Env) : Outcome
        silent = Env.new(env_of_repo.vars, env_of_repo.dir, IO::Memory.new, IO::Memory.new, env_of_repo.now)
        Tasks::GenerateFiles.new(Config.load(silent), silent).run
        {:ok, nil}
      rescue error : Error
        {:fail, "generate-files failed: #{error.message}"}
      end

      # The same, for the repository at `dir` of a fleet: the repository's
      # `.env` completes the fleet's variables, as it does on the image side
      # (a variable already set wins). A `.env` donico refuses is that
      # repository's failure, not an exception.
      def self.call(fleet_env : Env, dir : String) : Outcome
        call(Env.new(Dotenv.load(dir, fleet_env.vars), dir, fleet_env.stdout, fleet_env.stderr, fleet_env.now))
      rescue error : Error
        {:fail, "generate-files failed: #{error.message}"}
      end
    end
  end
end
