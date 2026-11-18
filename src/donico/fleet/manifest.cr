require "yaml"

require "../config"
require "../env"
require "../error"

module Donico
  module Fleet
    # What a fleet is: where its images live and how each of them is treated.
    # Read from a `donico-manager.yml` at the root of the fleet's configuration
    # repository, with the parser `donico.yml` is read with, so that both files
    # resolve merge keys the way the Ruby gem did.
    #
    # What lives in each image's own donico.yml (category, description) is
    # deliberately absent: the generators read it at the source, and repeating
    # it here would create two truths that drift. `commit_linter` is accepted
    # and ignored (`lint-commits` is not ported), so an existing manifest still
    # loads.
    class Manifest
      FILE = "donico-manager.yml"

      REQUIRED = %w[registry group workspace images]

      # An unknown key is refused rather than ignored: read as "no policy", a
      # typo would silently treat the image like every other one.
      POLICIES = %w[check_versions bump_donico constrain pinned]

      # Where the heritage tree is written when the fleet does not say otherwise.
      DEFAULT_HERITAGE_OUTPUT = "doc/image-heritage.md"

      # The policies of one image, defaults included.
      private record Policy, check_versions : Bool = true, bump_donico : Bool = true,
        constrain : String? = nil, pinned : Bool = false

      getter registry : String
      getter group : String
      getter workspace : String
      getter registries : Hash(String, String)
      getter browse_url : String?
      getter ci_config_url : String?
      getter heritage_output : String
      getter debian_images : Array(String)
      getter categories : Array(String)

      @policies : Hash(String, Policy)

      def self.load(env : Env) : Manifest
        path = File.join(env.dir, FILE)
        unless File.file?(path)
          raise ManifestError.new("#{FILE} not found. donico-manager runs from the root of a fleet's configuration repository.")
        end
        text = begin
          File.read(path)
        rescue File::Error
          raise ManifestError.new("#{FILE}: cannot be read")
        end
        new(parse(text))
      end

      # The parser's own exception never escapes: it is one line of text for
      # the user, not a backtrace.
      private def self.parse(text : String) : Hash(YAML::Any, YAML::Any)
        document = PsychMergeParser.new(text, &.parse)
        raise ManifestError.new("#{FILE} is empty.") if document.raw.nil?
        document.as_h? || raise ManifestError.new("#{FILE}: expected a mapping at the top level.")
      rescue e : YAML::ParseException
        raise ManifestError.new("#{FILE}: invalid YAML: #{e.message.to_s.gsub(/\s*\n\s*/, " ")}")
      end

      protected def initialize(raw : Hash(YAML::Any, YAML::Any))
        raise ManifestError.new("#{FILE} is empty.") if raw.empty?
        require_keys(raw)

        @registry = required_string(raw, "registry")
        @group = required_string(raw, "group")
        @workspace = required_string(raw, "workspace")
        @registries = string_map(raw, "registries")
        @browse_url = string(raw, "browse_url")
        @ci_config_url = string(raw, "ci_config_url")
        @heritage_output = string(raw, "heritage_output") || DEFAULT_HERITAGE_OUTPUT
        @debian_images = string_list(raw, "debian_images")
        @categories = string_list(raw, "categories")
        @policies = parse_images(raw[YAML::Any.new("images")])
      end

      # Sorted here rather than at each call site: the report, the READMEs and
      # the sweeps all walk this list, and an order following the YAML would
      # make their output depend on how the file happened to be edited.
      def images : Array(String)
        @policies.keys.sort!
      end

      def clone_url(name : String) : String
        "#{group}/#{name}.git"
      end

      def check_versions?(name : String) : Bool
        policy(name).check_versions
      end

      def bump_donico?(name : String) : Bool
        policy(name).bump_donico
      end

      def constraint(name : String) : String?
        policy(name).constrain
      end

      # Distinct from check_versions: a pinned image is still scanned and
      # reported, it is simply never offered as an available update.
      def pinned?(name : String) : Bool
        policy(name).pinned
      end

      private def policy(name : String) : Policy
        @policies.fetch(name) { Policy.new }
      end

      # Named all at once rather than one at a time: a fleet setting up its
      # manifest wants the whole list of what it forgot, not the first item.
      private def require_keys(raw : Hash(YAML::Any, YAML::Any)) : Nil
        missing = REQUIRED.reject do |key|
          value = raw[YAML::Any.new(key)]?.try(&.raw)
          !value.nil? && value != false
        end
        raise ManifestError.new("#{FILE} is missing: #{missing.join(", ")}.") unless missing.empty?
      end

      # A blank value counts as absent: `browse_url:` with nothing after it is
      # no setting, not a wrong type.
      private def value(raw : Hash(YAML::Any, YAML::Any), key : String) : YAML::Any?
        found = raw[YAML::Any.new(key)]?
        found unless found.nil? || found.raw.nil?
      end

      private def string(raw : Hash(YAML::Any, YAML::Any), key : String) : String?
        found = value(raw, key) || return
        found.as_s? || raise ManifestError.new("#{FILE}: #{key} must be a string.")
      end

      # The key is known present and non-blank: require_keys ran first.
      private def required_string(raw : Hash(YAML::Any, YAML::Any), key : String) : String
        string(raw, key) || raise ManifestError.new("#{FILE} is missing: #{key}.")
      end

      private def string_list(raw : Hash(YAML::Any, YAML::Any), key : String) : Array(String)
        found = value(raw, key) || return [] of String
        items = found.as_a? || raise ManifestError.new("#{FILE}: #{key} must be a list of strings.")
        items.map { |item| item.as_s? || raise ManifestError.new("#{FILE}: #{key} must be a list of strings.") }
      end

      private def string_map(raw : Hash(YAML::Any, YAML::Any), key : String) : Hash(String, String)
        found = value(raw, key) || return {} of String => String
        entries = found.as_h? || raise ManifestError.new("#{FILE}: #{key} must be a mapping.")
        result = {} of String => String
        entries.each do |name, target|
          name_text = name.as_s? || raise ManifestError.new("#{FILE}: #{key} must be a mapping.")
          result[name_text] = target.as_s? || raise ManifestError.new("#{FILE}: #{key} must be a mapping.")
        end
        result
      end

      private def parse_images(list : YAML::Any) : Hash(String, Policy)
        items = list.as_a?
        raise ManifestError.new("#{FILE} declares no images.") if items.nil? || items.empty?

        policies = {} of String => Policy
        items.each_with_index do |entry, index|
          name, options = split(entry, index)
          policies[name] = build_policy(name, options)
        end
        policies
      end

      # Entries come in three shapes and only three: a bare name, a name whose
      # options are a mapping, and a name written with nothing after the colon
      # (which YAML parses as nil, not as an empty mapping). `- ruby: 3.4`
      # looks like the second and is not: its options are a scalar.
      private def split(entry : YAML::Any, index : Int32) : {String, Hash(YAML::Any, YAML::Any)}
        none = {} of YAML::Any => YAML::Any
        if name = entry.as_s?
          return {name, none}
        end

        pairs = entry.as_h?
        if pairs && pairs.size == 1
          key, options = pairs.first
          if name = key.as_s?
            return {name, none} if options.raw.nil?
            if mapping = options.as_h?
              return {name, mapping}
            end
          end
        end
        raise ManifestError.new("#{FILE}: images[#{index}] is neither an image name nor a name with options.")
      end

      private def build_policy(name : String, options : Hash(YAML::Any, YAML::Any)) : Policy
        unknown = options.keys.map(&.raw.to_s).reject { |key| POLICIES.includes?(key) }
        unless unknown.empty?
          noun = unknown.size > 1 ? "policies" : "policy"
          raise ManifestError.new("#{FILE}: #{name} declares unknown #{noun} #{unknown.join(", ")}. Known: #{POLICIES.join(", ")}.")
        end

        Policy.new(
          check_versions: boolean(options, "check_versions", true),
          bump_donico: boolean(options, "bump_donico", true),
          constrain: string(options, "constrain"),
          pinned: boolean(options, "pinned", false))
      end

      private def boolean(options : Hash(YAML::Any, YAML::Any), key : String, default : Bool) : Bool
        found = value(options, key) || return default
        case raw = found.raw
        when Bool then raw
        else           raise ManifestError.new("#{FILE}: #{key} must be a boolean.")
        end
      end
    end
  end
end
