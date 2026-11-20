require "yaml"

require "./env"
require "./error"
require "./image"
require "./matrix_entry"

module Donico
  # `YAML.parse` with the merge key (`<<`) resolved the way Psych resolves it,
  # since the Ruby gem loaded donico.yml with Psych and the same file must give
  # the same matrix. The two parsers agree on a single merged mapping (it is
  # applied where it stands: it overrides the keys written before it, the keys
  # written after it override it). They differ on a list of mappings: Psych
  # follows the YAML merge type, where the first mapping that defines a key
  # wins, while Crystal's parser lets the last one win.
  #
  # This is the stdlib's `YAML::Schema::Core::Parser#parse_mapping` (Crystal
  # 1.20) with that one loop changed. The class is undocumented stdlib: the
  # merge examples of spec/donico/config_spec.cr fail if an upgrade changes it.
  #
  # Not private: the fleet manifest (donico-manager.yml) is read with it too.
  class PsychMergeParser < YAML::Schema::Core::Parser
    protected def parse_mapping
      mapping = anchor new_mapping
      raw_mapping = mapping.as_h

      parse_mapping(mapping) do
        tag = @pull_parser.tag
        key = parse_node
        value = parse_node

        if key.raw == "<<" && tag != "tag:yaml.org,2002:str"
          case raw = value.raw
          when Hash
            raw_mapping.merge!(raw)
          when Array
            if raw.all? &.as_h?
              merged = {} of YAML::Any => YAML::Any
              raw.reverse_each { |element| merged.merge!(element.as_h) }
              raw_mapping.merge!(merged)
            else
              raw_mapping[key] = value
            end
          else
            raw_mapping[key] = value
          end
        else
          raw_mapping[key] = value
        end
      end

      mapping
    end
  end

  # The loaded and validated donico.yml of a project. `image_builder` names
  # the backend: "bake" (images built from a Dockerfile by `docker buildx
  # bake`) or "debuerreotype" (Debian root filesystems built by debuerreotype,
  # see Rootfs). Each backend validates its own keys and ignores the other's.
  class Config
    FILE = "donico.yml"

    BUILDERS = %w[bake debuerreotype]

    # Macros usable in a tag. bake resolves the platform list itself, so no
    # single arch exists when its tags are built.
    TAG_MACROS = %w[distro timestamp version]

    getter registry : String
    getter image_name : String?
    getter image_builder : String
    getter matrix : Array(MatrixEntry)
    # Where the tool images live when the project names a registry for them;
    # nil when it does not (see `ToolImages`).
    getter tools_registry : String?
    getter docker_linter : String?
    getter inspec_image : String?

    # The two top-level keys of the debuerreotype backend, nil under bake.
    getter apt_proxy : String?
    getter debuerreotype_image : String?

    def self.load(env : Env) : Config
      path = File.join(env.dir, FILE)
      raise ConfigError.new("#{FILE} not found in #{env.dir}") unless File.file?(path)
      text = begin
        File.read(path)
      rescue File::Error
        raise ConfigError.new("#{FILE}: cannot be read")
      end
      new(parse(text), env)
    end

    # The mapping at the top of the file. The parser's own exception never
    # escapes: it is one line of text for the user, not a backtrace.
    private def self.parse(text : String) : Hash(YAML::Any, YAML::Any)
      document = PsychMergeParser.new(text, &.parse)
      raise ConfigError.new("#{FILE}: a value holds a NUL character") if nul?(document)
      document.as_h? || raise ConfigError.new("#{FILE}: expected a mapping at the top level")
    rescue e : YAML::ParseException
      raise ConfigError.new("#{FILE}: invalid YAML: #{e.message.to_s.gsub(/\s*\n\s*/, " ")}")
    end

    # A NUL can be written in YAML (`"\\0"`) but neither an argument nor an
    # environment variable can hold one: the spawn of the first child would
    # fail on it with a backtrace. Keys included.
    private def self.nul?(any : YAML::Any) : Bool
      case raw = any.raw
      when String then raw.includes?('\0')
      when Array  then raw.any? { |item| nul?(item) }
      when Hash   then raw.any? { |key, value| nul?(key) || nul?(value) }
      else             false
      end
    end

    protected def initialize(raw : Hash(YAML::Any, YAML::Any), @env : Env)
      @registry = string(raw, "registry") || raise ConfigError.new("#{FILE}: missing required key: registry")
      @image_builder = image_builder_of(raw)
      @image_name = debuerreotype? ? nil : image_name_of(raw)
      @matrix = matrix_of(raw)
      @tools_registry = string(raw, "tools_registry")
      @docker_linter = string(raw, "docker_linter")
      @inspec_image = string(raw, "inspec_image")
      @apt_proxy = debuerreotype? ? apt_proxy_of(raw) : nil
      @debuerreotype_image = debuerreotype? ? string(raw, "debuerreotype_image") : nil
      @timestamp = nil.as(String?)

      if debuerreotype?
        validate_unique_distros
      else
        validate_image_names
        validate_tags
        validate_unique_rows
        validate_reserved_args
      end
    end

    def debuerreotype? : Bool
      @image_builder == "debuerreotype"
    end

    # The default timestamp of a debuerreotype row: the day before the run,
    # as danico computed it (`Date.today.to_time - 1`, one second before
    # midnight). `build` and `push` must agree on it, since it names the
    # tarballs, and they run as two CI jobs that midnight may separate: under
    # GitLab CI the day is therefore the one the pipeline was created on
    # (CI_PIPELINE_CREATED_AT, ISO 8601, in its own offset), which every job
    # of the pipeline shares. Computed on use, not at load: a bad value must
    # not break the tasks that need no timestamp.
    def rootfs_timestamp : String
      (rootfs_day.at_beginning_of_day - 1.second).to_s("%Y%m%d")
    end

    private def rootfs_day : Time
      created = @env.vars["CI_PIPELINE_CREATED_AT"]?
      return @env.now if created.nil? || created.empty?
      Time.parse_iso8601(created)
    rescue Time::Format::Error | ArgumentError | Time::Location::InvalidTimezoneOffsetError
      raise ConfigError.new(%(CI_PIPELINE_CREATED_AT is not an ISO 8601 timestamp: "#{created}"))
    end

    # The APT proxy the build of a root filesystem goes through: `apt_proxy`,
    # unless ENABLE_APT_PROXY is "false" (process environment or .env).
    def build_proxy : String?
      @apt_proxy unless @env.vars["ENABLE_APT_PROXY"]? == "false"
    end

    # CI_COMMIT_TIMESTAMP (ISO 8601) reformatted in its own offset, else the
    # date of the clock. Computed on first use, not at load: a bad value must
    # not break the tasks that never need a timestamp. Memoized so every image
    # of a run shares one build tag, even across midnight.
    def timestamp : String
      @timestamp ||= begin
        ci = @env.vars["CI_COMMIT_TIMESTAMP"]?
        if ci && !ci.empty?
          begin
            Time.parse_iso8601(ci).to_s("%Y%m%d%H%M%S")
          rescue Time::Format::Error | ArgumentError | Time::Location::InvalidTimezoneOffsetError
            # Out-of-range fields (month 13) and offsets (+99:00) pass the
            # format but are refused by Time itself, with other exceptions.
            raise ConfigError.new(%(CI_COMMIT_TIMESTAMP is not an ISO 8601 timestamp: "#{ci}"))
          end
        else
          @env.now.to_s("%Y%m%d")
        end
      end
    end

    # Deduplicated: `dockerfile` defaults to "Dockerfile", so N distros would
    # otherwise lint the same file N times. /app is where the linter container
    # mounts the project.
    def dockerfiles : Array(String)
      dockerfiles = @matrix.map { |entry| "/app/#{entry.dockerfile}" }
      dockerfiles.uniq!
    end

    # A string-valued key, nil when absent, null or empty: `registry: ""` is
    # not a registry, and passing it on gave tags such as `/name:latest`.
    private def string(raw : Hash(YAML::Any, YAML::Any), key : String) : String?
      found = raw[YAML::Any.new(key)]?
      return if found.nil? || found.raw.nil?
      text = found.as_s? || raise ConfigError.new("#{FILE}: #{key} must be a string")
      text unless text.empty?
    end

    private def image_name_of(raw) : String?
      name = string(raw, "image_name") || return
      return name if name.matches?(MatrixEntry::IMAGE_NAME)
      raise ConfigError.new(%(#{FILE}: image_name "#{name}" is invalid (allowed: letters, digits, ., _, - and /)))
    end

    private def image_builder_of(raw) : String
      builder = string(raw, "image_builder") || "bake"
      return builder if BUILDERS.includes?(builder)
      if builder == "docker"
        raise ConfigError.new(%(#{FILE}: image_builder "docker" is not supported by donico 3, use image_builder: bake))
      end
      raise ConfigError.new(%(#{FILE}: unknown image_builder "#{builder}" (supported: #{BUILDERS.join(", ")})))
    end

    # The proxy is written into the build script, like the values of a row.
    private def apt_proxy_of(raw) : String?
      proxy = string(raw, "apt_proxy") || return
      MatrixEntry.script_word(proxy, "apt_proxy")
    end

    # `matrix` absent means one row with every default under bake. The
    # debuerreotype backend has no default distro to build: it needs the list.
    private def matrix_of(raw) : Array(MatrixEntry)
      found = raw[YAML::Any.new("matrix")]?
      if found.nil? || found.raw.nil?
        raise ConfigError.new("#{FILE}: matrix is required with image_builder: debuerreotype") if debuerreotype?
        return [MatrixEntry.new({} of YAML::Any => YAML::Any, 0)]
      end
      rows = found.as_a? || raise ConfigError.new("#{FILE}: matrix must be a list of mappings")
      rows.map_with_index do |row, index|
        mapping = row.as_h? || raise ConfigError.new("#{FILE}: matrix must be a list of mappings")
        MatrixEntry.new(mapping, index, rootfs: debuerreotype?)
      end
    end

    # The name may come from the top level or from the row, but it has to come
    # from somewhere: a nil name rendered tags with an empty segment and a
    # version variable called "_VERSION".
    private def validate_image_names : Nil
      return if @matrix.all? { |entry| entry.image_name || @image_name }
      raise ConfigError.new("#{FILE}: missing image_name (set it at the top level or on every matrix entry)")
    end

    # Any `%` left once the allowed macros are removed is either an unknown
    # macro or a literal percent sign, which a tag cannot carry. What is left
    # then has to be what docker accepts in a tag, and the tag is not empty.
    private def validate_tags : Nil
      allowed = Regex.new("%<(#{TAG_MACROS.join('|')})>s")
      macros = TAG_MACROS.map { |name| "%<#{name}>s" }.join(", ")
      @matrix.each do |entry|
        entry.tags.each do |tag|
          rest = tag.gsub(allowed, "")
          if rest.includes?('%')
            raise ConfigError.new(%(#{FILE}: invalid tag "#{tag}" (allowed macros: #{macros}; a literal % is not supported)))
          end
          next if !tag.empty? && rest.matches?(/\A[A-Za-z0-9_.-]*\z/)
          raise ConfigError.new(%(#{FILE}: invalid tag "#{tag}" (a tag holds letters, digits, ., _ and -, and the macros #{macros})))
        end
      end
    end

    # Two rows with one distro and version would build the same target twice;
    # Rake used to merge their tasks without a word. Two different rows can
    # still share a target, since the dots of a version become dashes there
    # ("1.0" and "1-0"): bake would merge the two blocks and build the second
    # row under the name of the first.
    private def validate_unique_rows : Nil
      seen = {} of String => Int32
      targets = {} of String => Int32
      @matrix.each_with_index do |entry, index|
        key = "#{entry.distro}:#{entry.version}"
        if first = seen[key]?
          raise ConfigError.new("#{FILE}: matrix[#{index}] duplicates matrix[#{first}] (#{key})")
        end
        seen[key] = index

        target = Image.target_stem(entry.distro, entry.version)
        if first = targets[target]?
          raise ConfigError.new("#{FILE}: matrix[#{index}] and matrix[#{first}] give the same bake target (#{target})")
        end
        targets[target] = index
      end
    end

    # A debuerreotype row gives the image `<registry>/<distro>`, and its build
    # directories and tarballs are named after the distro: two rows of one
    # distro would overwrite each other, whatever their versions.
    private def validate_unique_distros : Nil
      seen = {} of String => Int32
      @matrix.each_with_index do |entry, index|
        if first = seen[entry.distro]?
          raise ConfigError.new("#{FILE}: matrix[#{index}] and matrix[#{first}] build the same image (#{entry.distro})")
        end
        seen[entry.distro] = index
      end
    end

    # DISTRO_NAME, BUILD_DATE and <NAME>_VERSION are written by donico. A
    # declared arg of the same name used to be written next to the injected
    # one: bake kept the last of the two, in alphabetical order of the values,
    # so which one reached the Dockerfile depended on what they were.
    private def validate_reserved_args : Nil
      @matrix.each_with_index do |entry, index|
        name = entry.image_name || @image_name || next
        reserved = Image.injected_names(name)
        entry.build_args.each_with_index do |arg, position|
          key = arg.partition('=').first
          next unless reserved.includes?(key)
          raise ConfigError.new("#{FILE}: matrix[#{index}].build_args[#{position}] sets #{key}, which donico sets itself (reserved: #{reserved.join(", ")})")
        end
      end
    end
  end
end
