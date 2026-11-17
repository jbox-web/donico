require "../env"
require "../image"
require "../runner"

module Donico
  module Tasks
    # Opens a shell in the built image. Each `login_env` name is passed as a
    # bare `-e NAME`, so docker copies the value from the environment of the
    # call instead of the secret appearing on a command line.
    class Login
      def initialize(@image : Image, @env : Env, @runner : Runner)
      end

      def run : Int32
        args = ["run", "-it", "--rm"]
        @image.entry.login_env.each { |name| args.concat(["-e", name]) }
        args.concat([@image.build_tag, "/bin/bash"])
        @runner.exec("docker", args)
      end
    end
  end
end
