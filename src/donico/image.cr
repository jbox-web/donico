require "./config"
require "./matrix_entry"

module Donico
  # The values derived from one matrix row: tags, build args, Inspec inputs and
  # target names. The timestamp comes from the config on first use, so building
  # an image never fails on a bad CI_COMMIT_TIMESTAMP.
  class Image
    getter name : String
    getter registry : String
    getter distro : String
    getter version : String
    getter entry : MatrixEntry

    def self.all(config : Config) : Array(Image)
      config.matrix.map { |entry| new(config, entry) }
    end

    def initialize(@config : Config, @entry : MatrixEntry)
      # The row's name is the more specific declaration; Config guarantees one
      # of the two exists.
      @name = @entry.image_name || @config.image_name || raise "invariant: Config rejects a matrix row without an image name"
      @registry = @config.registry
      @distro = @entry.distro
      @version = @entry.version
    end

    def build_tag : String
      "#{name}/#{version}/#{distro}:#{@config.timestamp}"
    end

    # Sorted after expansion, so the order does not depend on the file. The
    # timestamp is read even when no tag uses it: like the gem, a bad
    # CI_COMMIT_TIMESTAMP fails every command that derives tags.
    def prod_tags : Array(String)
      timestamp = @config.timestamp
      entry.tags.map { |tag| "#{registry}/#{name}:#{expand(tag, timestamp)}" }.sort!
    end

    # Declared args plus the injected ones, sorted as plain strings (byte
    # order: upper case before lower case).
    def raw_build_args : Array(String)
      (entry.build_args + injected_args).sort!
    end

    # What `build` and `push` add to the environment of `docker buildx bake`:
    # BUILD_DATE, the one value the bakefile declares as a variable and reads
    # from there. Every other arg is written in the bakefile itself. The gem
    # exported them all, which let an arg named PATH, DOCKER_HOST or
    # BUILDX_BUILDER reconfigure the docker client instead of only reaching
    # the Dockerfile.
    def bake_env : Hash(String, String)
      {"BUILD_DATE" => @config.timestamp}
    end

    # Sorted first, lower-cased afterwards: the order is the one the gem
    # produces. Only the name is lower-cased, a value is case sensitive
    # (tokens, base64 payloads); an item without `=` is lower-cased whole.
    def inspec_inputs : Array(String)
      (entry.build_args + entry.test_args + injected_args).sort!.map do |arg|
        key, separator, value = arg.partition('=')
        "#{key.downcase}#{separator}#{value}"
      end
    end

    def build_target : String
      "#{Image.target_stem(distro, version)}-build"
    end

    def push_target : String
      "#{Image.target_stem(distro, version)}-push"
    end

    # What the two targets of a row share. A bake target only holds letters,
    # digits, `_` and `-`, so the dots of the version become dashes; Config
    # refuses two rows that end up with the same stem.
    def self.target_stem(distro : String, version : String) : String
      "#{distro}-#{version.tr(".", "-")}"
    end

    def task_prefix : String
      @entry.task_prefix
    end

    # Literal substitution of the three macros Config allows. No format
    # function: the tag is user text, and one pass keeps a substituted value
    # from being expanded again.
    private def expand(tag : String, timestamp : String) : String
      tag.gsub(/%<(version|distro|timestamp)>s/) do |_, match|
        case match[1]
        when "version" then version
        when "distro"  then distro
        else                timestamp
        end
      end
    end

    private def injected_args : Array(String)
      ["DISTRO_NAME=#{distro}", "BUILD_DATE=#{@config.timestamp}", "#{Image.version_variable(name)}=#{version}"]
    end

    # The names of the build args donico writes itself for an image called
    # `name`. A row may not declare one of them: Config refuses it.
    def self.injected_names(name : String) : Array(String)
      ["BUILD_DATE", "DISTRO_NAME", version_variable(name)]
    end

    # `<NAME>_VERSION`, the name in upper snake case. The gem's `underscore`
    # (the two camel-case splits, `-` to `_`), then every character an argument
    # name cannot hold becomes an underscore too: an image name may hold `/`
    # and `.`, and `team/node.js` used to give `TEAM/NODE.JS_VERSION`, which
    # bake refuses.
    def self.version_variable(name : String) : String
      snake = name
        .gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
        .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
        .gsub(/[^A-Za-z0-9_]/, "_")
      "#{snake.upcase}_VERSION"
    end
  end
end
