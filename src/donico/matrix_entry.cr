require "yaml"

require "./config"
require "./error"

module Donico
  # One row of the `matrix` list of donico.yml, validated when it is built so a
  # bad file is rejected before any docker command starts. `index` is the
  # zero-based position of the row: it only appears in error paths.
  class MatrixEntry
    getter image_name : String?
    getter version : String
    getter distro : String
    getter archs : Array(String)
    getter dockerfile : String
    getter build_args : Array(String)
    getter test_args : Array(String)
    getter secret_envs : Array(Hash(String, String))
    getter secret_files : Array(Hash(String, String))
    getter tags : Array(String)
    getter test_variants : Array(Array(String))
    getter login_env : Array(String)

    def initialize(raw : Hash(YAML::Any, YAML::Any), @index : Int32)
      @image_name = image_name_of(raw)
      @version = version_of(raw)
      @distro = distro_of(raw)
      @archs = strings_or(raw, "archs", ["linux/amd64"])
      @dockerfile = dockerfile_of(raw)
      @build_args = build_args_of(raw)
      @test_args = strings_or(raw, "test_args", [] of String)
      @secret_envs = secrets_of(raw, "secret_envs", %w[id])
      @secret_files = secrets_of(raw, "secret_files", %w[id src])
      @tags = strings_or(raw, "tags", ["%<version>s-%<distro>s"])
      @test_variants = variants_of(raw)
      @login_env = strings_or(raw, "login_env", [] of String)
    end

    # The value of `key`, or nil when it is absent or written as null: an
    # empty `key:` means "not set", like a missing key.
    private def value(raw : Hash(YAML::Any, YAML::Any), key : String) : YAML::Any?
      found = raw[YAML::Any.new(key)]?
      found unless found.nil? || found.raw.nil?
    end

    private def path(key : String) : String
      "matrix[#{@index}].#{key}"
    end

    private def fail(message : String) : NoReturn
      raise ConfigError.new("#{Config::FILE}: #{message}")
    end

    private def string_or(raw, key : String, default : String?) : String?
      found = value(raw, key)
      return default unless found
      found.as_s? || fail("#{path(key)} must be a string")
    end

    private def string_or(raw, key : String, default : String) : String
      found = value(raw, key)
      return default unless found
      found.as_s? || fail("#{path(key)} must be a string")
    end

    private def strings_or(raw, key : String, default : Array(String)) : Array(String)
      found = value(raw, key)
      return default unless found
      strings_of(found) || fail("#{path(key)} must be a list of strings")
    end

    # An image name as docker writes one: path components of letters, digits,
    # `.`, `_` and `-`. An empty name means "not set", like a missing key, so
    # the row falls back on the top-level name.
    IMAGE_NAME = /\A[A-Za-z0-9._\/-]+\z/

    # The name of a build arg: an identifier, for HCL (the bakefile) and for
    # the Inspec harness, which exports every input to its hooks.
    ARG_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    private def image_name_of(raw) : String?
      name = string_or(raw, "image_name", nil)
      return if name.nil? || name.empty?
      return name if name.matches?(IMAGE_NAME)
      fail(%(#{path("image_name")} "#{name}" is invalid (allowed: letters, digits, ., _, - and /)))
    end

    # The distro is a part of the bake target, of the build tag and of the
    # task name, which is split on its colons.
    private def distro_of(raw) : String
      distro = string_or(raw, "distro", "buster")
      return distro if distro.matches?(/\A[A-Za-z0-9_-]+\z/)
      fail(%(#{path("distro")} "#{distro}" is invalid (allowed: letters, digits, _ and -)))
    end

    private def dockerfile_of(raw) : String
      dockerfile = string_or(raw, "dockerfile", "Dockerfile")
      fail("#{path("dockerfile")} must not be empty") if dockerfile.empty?
      dockerfile
    end

    # Every build arg is rendered as a KEY=VALUE pair (bake arguments, build
    # arg hash), so an item without `=` or with an empty key is refused here,
    # like a name that is not an identifier and a name given twice (bake kept
    # the last of the two in alphabetical order of their values). An empty
    # value is legal. test_args are not concerned: an Inspec input without `=`
    # is valid.
    private def build_args_of(raw) : Array(String)
      args = strings_or(raw, "build_args", [] of String)
      seen = Set(String).new
      args.each_with_index do |arg, i|
        key, separator, _ = arg.partition('=')
        fail("#{path("build_args")}[#{i}] must be KEY=VALUE") if separator.empty? || key.empty?
        unless key.matches?(ARG_NAME)
          fail(%(#{path("build_args")}[#{i}] has an invalid name "#{key}" (letters, digits and underscores, not starting with a digit)))
        end
        fail("#{path("build_args")}[#{i}] sets #{key} a second time") unless seen.add?(key)
      end
      args
    end

    # The items of `any` when it is a list of strings only, nil otherwise: an
    # unquoted number in a list is almost always a typo for a string.
    private def strings_of(any : YAML::Any) : Array(String)?
      list = any.as_a? || return
      list.map { |item| item.as_s? || return }
    end

    # YAML types an unquoted 3.10 as the float 3.1; calling #to_s on it would
    # build and tag an image under a version the user never wrote, and the
    # original text cannot be recovered. The file is refused instead.
    #
    # The version is a part of the bake target (dots become dashes) and of the
    # build tag: a character neither accepts is refused here too.
    private def version_of(raw) : String
      found = value(raw, "version")
      return "latest" unless found
      version = found.as_s? || fail(%(#{path("version")} must be a quoted string (YAML read it as #{found.raw}; quote it as written in the file)))
      return version if version.matches?(/\A[A-Za-z0-9._-]+\z/)
      fail(%(#{path("version")} "#{version}" is invalid (allowed: letters, digits, ., _ and -)))
    end

    private def variants_of(raw) : Array(Array(String))
      found = value(raw, "test_variants")
      return [] of Array(String) unless found
      list = found.as_a? || fail("#{path("test_variants")} must be a list of lists of strings")
      list.map do |variant|
        strings_of(variant) || fail("#{path("test_variants")} must be a list of lists of strings")
      end
    end

    # A secret missing its id used to render as `id = ""` in the bakefile:
    # valid HCL that silently mounts nothing. An empty value counts as missing.
    private def secrets_of(raw, key : String, required : Array(String)) : Array(Hash(String, String))
      found = value(raw, key)
      return [] of Hash(String, String) unless found
      list = found.as_a? || fail("#{path(key)} must be a list of mappings")
      list.map_with_index do |item, i|
        mapping = item.as_h? || fail("#{path(key)} must be a list of mappings")
        entry = {} of String => String
        mapping.each do |k, v|
          next if v.raw.nil?
          name = k.as_s? || fail("#{path(key)}[#{i}] must have string keys")
          entry[name] = v.as_s? || fail("#{path(key)}[#{i}].#{name} must be a string")
        end
        missing = required.select { |name| entry[name]?.try(&.empty?) != false }
        unless missing.empty?
          fail("#{path(key)}[#{i}] is missing required #{missing.size > 1 ? "keys" : "key"}: #{missing.join(", ")}")
        end
        entry
      end
    end
  end
end
