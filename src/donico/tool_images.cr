require "./config"

module Donico
  # The two images the binary runs besides the project's own: the Dockerfile
  # linter and Inspec. An explicit key wins; otherwise the image lives under
  # `tools_registry`, which defaults to `registry`.
  record ToolImages, docker_linter : String, inspec : String do
    def self.from(config : Config) : ToolImages
      new(
        config.docker_linter || "#{config.tools_registry}/hadolint:latest",
        config.inspec_image || "#{config.tools_registry}/inspec:latest",
      )
    end
  end
end
