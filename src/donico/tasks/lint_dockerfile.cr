require "../config"
require "../env"
require "../runner"

module Donico
  module Tasks
    # Runs the Dockerfile linter image on every distinct Dockerfile of the
    # matrix. Every run happens even after a failure, so one pass reports every
    # violation. The result drives the exit status: a linter whose result is
    # never inspected leaves a CI job green whatever the Dockerfile holds.
    class LintDockerfile
      def initialize(@config : Config, @env : Env, @runner : Runner, @docker_linter : String)
      end

      def run : Int32
        failed = false
        outputs = [] of String

        @config.dockerfiles.each do |file|
          # The working directory is /app on purpose: hadolint looks for the
          # project's .hadolint.yaml there. It is set here, not left to the
          # image: the public hadolint image works in /, where the lint
          # reported rules the project had waived.
          code, text = @runner.capture("docker", [
            "run", "--pull", "always", "--rm",
            "-e", "MISE_IGNORED_CONFIG_PATHS=/app/mise.toml",
            "--workdir", "/app",
            "-v", "#{@env.dir}:/app", @docker_linter, "hadolint", file,
          ])
          failed = true unless code == 0
          outputs << text unless text.empty?
        end

        return success unless failed
        @env.stdout.puts outputs.join("\n")
        1
      end

      private def success : Int32
        @env.stdout.puts "Dockerfile is OK!"
        0
      end
    end
  end
end
