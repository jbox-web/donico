require "./config"

module Donico
  # The images the binary runs besides the project's own: the Dockerfile
  # linter, Inspec and, for the debuerreotype backend, the image that holds
  # the debuerreotype scripts. For each one the first match wins: its explicit
  # key, then `<tools_registry>/<tool>:latest` when `tools_registry` is
  # written, then a public image, so that a project with no image of its own
  # needs no configuration.
  record ToolImages, docker_linter : String, inspec : String, debuerreotype : String do
    # The public defaults are pinned, not `latest`: one donico version runs
    # known tools. They are bumped with donico.
    PUBLIC_DOCKER_LINTER = "hadolint/hadolint:v2.15.1"
    PUBLIC_INSPEC        = "cincproject/auditor:7"
    # Published for linux/amd64 only.
    PUBLIC_DEBUERREOTYPE = "debuerreotype/debuerreotype:0.17"

    def self.from(config : Config) : ToolImages
      tools = config.tools_registry
      new(
        config.docker_linter || (tools ? "#{tools}/hadolint:latest" : PUBLIC_DOCKER_LINTER),
        config.inspec_image || (tools ? "#{tools}/inspec:latest" : PUBLIC_INSPEC),
        config.debuerreotype_image || (tools ? "#{tools}/debuerreotype:latest" : PUBLIC_DEBUERREOTYPE),
      )
    end
  end
end
