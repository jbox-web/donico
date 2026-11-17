require "../env"
require "../error"
require "../image"

module Donico
  module Tasks
    # buildx resolves a declared secret against the environment and, when the
    # variable is unset, silently falls back to reading a FILE named after the
    # id, then reports "failed to stat GITHUB_TOKEN": a file nobody mentioned,
    # which hides the real cause. donico knows what was declared, so it says
    # so before starting docker.
    module Secrets
      # Raises one ProblemList carrying every problem, one per secret,
      # `secret_envs` first and then `secret_files`, in declaration order.
      # Variables come from `env.vars` (process environment completed by
      # .env), never from the process's own ENV.
      def self.verify!(image : Image, env : Env) : Nil
        missing = missing_envs(image, env) + missing_files(image, env)
        raise ProblemList.new(missing) unless missing.empty?
      end

      private def self.missing_envs(image : Image, env : Env) : Array(String)
        image.entry.secret_envs
          .reject { |secret| env.vars.has_key?(secret["id"]) }
          .map { |secret| %(secret "#{secret["id"]}" is declared in secret_envs but the variable #{secret["id"]} is not set) }
      end

      # A src holding an HCL reference such as "${HOME}/.aws/credentials" is
      # resolved by bake itself: donico cannot stat it and must not claim it
      # is missing. A relative src is relative to the project directory.
      private def self.missing_files(image : Image, env : Env) : Array(String)
        image.entry.secret_files
          .reject { |secret| secret["src"].includes?("${") || File.exists?(File.expand_path(secret["src"], env.dir)) }
          .map { |secret| %(secret "#{secret["id"]}" is declared in secret_files but its src "#{secret["src"]}" does not exist) }
      end
    end
  end
end
