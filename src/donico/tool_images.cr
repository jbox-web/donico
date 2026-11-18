require "./config"

module Donico
  # The images the binary runs besides the project's own: the Dockerfile
  # linter, Inspec and, for the debuerreotype backend, the image that holds
  # the debuerreotype scripts. An explicit key wins; otherwise the image lives
  # under `tools_registry`, which defaults to `registry`.
  record ToolImages, docker_linter : String, inspec : String, debuerreotype : String do
    def self.from(config : Config) : ToolImages
      new(
        config.docker_linter || "#{config.tools_registry}/hadolint:latest",
        config.inspec_image || "#{config.tools_registry}/inspec:latest",
        config.debuerreotype_image || "#{config.tools_registry}/debuerreotype:latest",
      )
    end
  end
end
