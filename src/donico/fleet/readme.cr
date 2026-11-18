require "yaml"

require "../env"
require "../error"
require "./repos"

module Donico
  module Fleet
    # What the two README generators share: how an image's own configuration is
    # found and read, and how its values print. Read with a plain YAML parse and
    # never through `Config.load`: the fleet's READMEs must still list an image
    # that donico 3 refuses (an unquoted `version: 3.10`, a reserved build arg).
    # A scalar prints as the YAML parser reads it, so that 3.10 is 3.1, which is
    # what the Ruby gem (Psych) printed.
    module ImageConfig
      # debuerreotype names its configuration danico.yml: probed rather than
      # keyed on the image name, which would bake one fleet's exception in.
      FILES = %w[donico.yml danico.yml]

      # A regular file only: a directory of that name would fail at the read.
      # The bumper finds the file here too.
      def self.path(dir : String) : String?
        FILES.map { |name| File.join(dir, name) }.find { |file| File.file?(file) }
      end

      # The parsed document, or nil when the file is not YAML. An empty file is
      # a document whose raw value is nil.
      def self.read(path : String) : YAML::Any?
        YAML.parse(File.read(path))
      rescue YAML::ParseException
        nil
      end

      # What Ruby's string interpolation gives: nothing for a missing value.
      def self.text(value : YAML::Any?) : String
        value.nil? || value.raw.nil? ? "" : value.raw.to_s
      end

      # The value of `key`, or nil when it is absent or null.
      def self.string?(map : Hash(YAML::Any, YAML::Any), key : String) : String?
        found = map[YAML::Any.new(key)]?
        found.nil? || found.raw.nil? ? nil : text(found)
      end

      # `%<version>s` and `%<distro>s` replaced, anything else left as written.
      def self.tag(pattern : String, version : String, distro : String) : String
        pattern.gsub(/%<(version|distro)>s/) { |match| match == "%<version>s" ? version : distro }
      end

      # The version of a matrix row: `latest` when the key is missing.
      def self.version(row : Hash(YAML::Any, YAML::Any)) : String
        row.has_key?(YAML::Any.new("version")) ? text(row[YAML::Any.new("version")]) : "latest"
      end

      def self.rows(config : Hash(YAML::Any, YAML::Any)) : Array(Hash(YAML::Any, YAML::Any))
        list = config[YAML::Any.new("matrix")]?.try(&.as_a?) || return [] of Hash(YAML::Any, YAML::Any)
        list.compact_map(&.as_h?)
      end

      # The patterns of a row, `%<version>s` when it declares none.
      def self.patterns(row : Hash(YAML::Any, YAML::Any)) : Array(String)
        list = row[YAML::Any.new("tags")]?.try(&.as_a?)
        list ? list.map { |entry| text(entry) } : ["%<version>s"]
      end
    end

    # Rewrites the fleet's root README from its template plus one table per
    # category, built from every image's donico.yml. The sections and their order
    # are the manifest's `categories`.
    class Readme
      TEMPLATE  = "templates/README.md"
      TODO_FILE = "todo.yml"

      private record Entry, tags : Array(String), github_repo : String

      def initialize(@repos : Repos, @env : Env)
      end

      # Everything that can fail does so before the README is written: a single
      # unreadable donico.yml must not leave the fleet with a truncated file.
      def run : Nil
        @env.stdout.puts "Updating README.md"

        template = File.join(@repos.root, TEMPLATE)
        raise Error.new("#{TEMPLATE} not found. The root README is generated from it.") unless File.exists?(template)

        planned = todo
        map = global_map
        text = String.build do |io|
          io << File.read(template)
          render_header(io, map)
          @repos.manifest.categories.each { |section| render_table(io, map[section]? || {} of String => Entry, planned[section]? || [] of String, section) }
        end
        File.write(File.join(@repos.root, "README.md"), text)

        @env.stdout.puts "Done!"
      end

      # The planned images by section. A fleet that plans none ships no file, an
      # empty file is nothing, and a file without an `images` mapping is as normal.
      private def todo : Hash(String, Array(String))
        path = File.join(@repos.root, TODO_FILE)
        planned = {} of String => Array(String)
        return planned unless File.exists?(path)

        document = begin
          YAML.parse(File.read(path))
        rescue YAML::ParseException
          raise Error.new("#{TODO_FILE}: invalid YAML.")
        end
        images = document.as_h?.try(&.[YAML::Any.new("images")]?).try(&.as_h?) || return planned
        images.each do |section, names|
          planned[ImageConfig.text(section)] = names.as_a?.try(&.map { |name| ImageConfig.text(name) }) || [] of String
        end
        planned
      end

      private def global_map : Hash(String, Hash(String, Entry))
        debian_images = @repos.manifest.debian_images
        map = {} of String => Hash(String, Entry)
        @repos.all.each do |image|
          config = config_for(image) || next
          category = ImageConfig.text(config[YAML::Any.new("category")]?)
          tags = collect_tags(image, config, debian_images)
          (map[category] ||= {} of String => Entry)[image] = Entry.new(tags, ImageConfig.text(config[YAML::Any.new("github_repo")]?))
        end
        map
      end

      # The config of one image, or nil with a reason on stdout. A partial
      # workspace and a half-written donico.yml are both normal states of a
      # fleet; neither may cost the whole README.
      private def config_for(image : String) : Hash(YAML::Any, YAML::Any)?
        path = ImageConfig.path(@repos.path(image)) || return skip(image, "not cloned")
        document = ImageConfig.read(path)
        return skip(image, "donico.yml does not parse") if document.nil? || document.raw.nil?

        config = document.as_h? || return skip(image, "donico.yml declares no matrix")
        return skip(image, "donico.yml declares no matrix") unless config[YAML::Any.new("matrix")]?.try(&.as_a?)
        return skip(image, "donico.yml declares no category") if ImageConfig.text(config[YAML::Any.new("category")]?).empty?

        config
      end

      private def skip(image : String, reason : String) : Nil
        @env.stdout.puts "  skip #{image} (#{reason})"
        nil
      end

      # The tags of the root README name the image after its directory, the
      # distro for the images the manifest lists as `debian_images`, and carry
      # the image's own registry (no fallback, unlike the image README).
      private def collect_tags(image : String, config : Hash(YAML::Any, YAML::Any), debian_images : Array(String)) : Array(String)
        registry = ImageConfig.text(config[YAML::Any.new("registry")]?)
        tags = [] of String
        ImageConfig.rows(config).each do |row|
          version = ImageConfig.version(row)
          distro = ImageConfig.text(row[YAML::Any.new("distro")]?)
          name = debian_images.includes?(image) ? distro : image
          ImageConfig.patterns(row).each { |pattern| tags << "#{registry}/#{name}:#{ImageConfig.tag(pattern, version, distro)}" }
        end
        tags
      end

      private def render_header(io : IO, map : Hash(String, Hash(String, Entry))) : Nil
        io << "## Total images : " << map.values.sum(&.size) << "\n\n"
      end

      private def render_table(io : IO, images : Hash(String, Entry), todos : Array(String), section : String) : Nil
        io << "## " << section.capitalize << " (" << images.size << ")\n\n"
        io << "| Image | CI Status | Upstream | Registry link |\n"
        io << "|-------|-----------|----------|---------------|\n"

        images.keys.sort!.each do |image|
          @env.stdout.puts "Adding badge for #{image}"
          io << render_row(image, images[image]) << '\n'
        end
        todos.each do |todo|
          @env.stdout.puts "Adding badge for #{todo}"
          io << "| *" << todo << "* | *todo* | *todo* | *todo* |\n"
        end
        io << '\n'
      end

      private def render_row(image : String, entry : Entry) : String
        browse_url = @repos.manifest.browse_url.to_s
        pipelines = "#{browse_url}/#{image}/-/pipelines"
        badge = "[![pipeline status](#{browse_url}/#{image}/badges/master/pipeline.svg)](#{pipelines})"

        version = ""
        unless entry.github_repo.empty?
          parts = entry.github_repo.split('/')
          owner = parts[0]
          project = parts[1]? || ""
          version = "[![GitHub Release](https://img.shields.io/github/v/release/#{owner}/#{project})](https://github.com/#{owner}/#{project}/releases)"
        end
        registry = entry.tags.map { |tag| "<li><code>#{tag}</code></li>" }.uniq!.join

        "| [#{image}](#{browse_url}/#{image}) | <ul>#{badge}</ul> | <ul>#{version}</ul> | <ul>#{registry}</ul> |"
      end
    end
  end
end
