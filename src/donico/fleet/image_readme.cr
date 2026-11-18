require "./readme"

module Donico
  module Fleet
    # Rewrites the README.md of every cloned image repository from its own
    # donico.yml. The layout is the organisation's (its French labels included)
    # and stays here; what a fleet declares is where its CI variables live and
    # which images name their tags after the distro.
    class ImageReadme
      DEFAULT_DESCRIPTION = "_TODO: ajouter une description dans donico.yml_"

      def initialize(@repos : Repos, @env : Env)
      end

      # `repo` limits the run to one image; a name the manifest does not declare
      # is an error.
      def run(repo : String? = nil) : Nil
        updated = 0
        skipped = 0

        @repos.resolve(repo).each do |image|
          if write(image)
            updated += 1
          else
            skipped += 1
          end
        end

        @env.stdout.puts "\nDone! #{updated} README(s) updated, #{skipped} skipped."
      end

      # True when the README was written. An unreadable config skips its image
      # and never abandons the sweep: the images already visited would keep their
      # new README, the ones after it never be reached, and nothing would say
      # which is which.
      private def write(image : String) : Bool
        path = @repos.path(image)
        unless Dir.exists?(path)
          @env.stdout.puts "  skip #{image} (not cloned)"
          return false
        end

        file = ImageConfig.path(path)
        if file.nil?
          @env.stdout.puts "  skip #{image} (no donico.yml)"
          return false
        end

        config = ImageConfig.read(file).try(&.as_h?)
        if config.nil?
          @env.stdout.puts "  skip #{image} (donico.yml is empty or does not parse)"
          return false
        end

        readme = File.join(path, "README.md")
        File.write(readme, generate(image, config))
        @env.stdout.puts "  updated #{readme}"
        true
      end

      private def generate(image : String, config : Hash(YAML::Any, YAML::Any)) : String
        image_name = ImageConfig.string?(config, "image_name") || image
        description = ImageConfig.string?(config, "description") || DEFAULT_DESCRIPTION
        category = ImageConfig.string?(config, "category") || "?"
        github_repo = ImageConfig.string?(config, "github_repo")
        registry = ImageConfig.string?(config, "registry") || @repos.manifest.registry
        tags = build_tags(image, registry, config)

        String.build do |io|
          io << "# " << image_name << "\n\n"
          io << description << "\n\n"

          io << "**Catégorie :** " << category
          io << " · **Upstream :** [" << github_repo << "](https://github.com/" << github_repo << ")" if github_repo && !github_repo.empty?
          io << "\n\n"

          unless tags.empty?
            io << "**Tags disponibles :**\n\n"
            tags.each { |tag| io << "- `" << tag << "`\n" }
            io << "\n**Utilisation :**\n\n```dockerfile\nFROM " << tags.first << "\n```\n\n"
          end

          io << "## Commandes\n\n```sh\ndonico help\n```\n\n"
          io << "## CI Config\n\n"
          io << "Pour pousser les images Docker vers Harbor un token dédié a été créé, "
          io << "voir les [variables d'environnement du groupe](" << @repos.manifest.ci_config_url << ") pour plus d'informations.\n"
        end
      end

      # The tags of an image README name the image after its `image_name` (the
      # directory when it has none), or, for the manifest's `debian_images`, after
      # the `image_name` of each row, falling back on its distro.
      private def build_tags(image : String, registry : String, config : Hash(YAML::Any, YAML::Any)) : Array(String)
        debian = @repos.manifest.debian_images.includes?(image)
        tags = [] of String
        ImageConfig.rows(config).each do |row|
          version = ImageConfig.version(row)
          distro = ImageConfig.text(row[YAML::Any.new("distro")]?)
          name = debian ? (ImageConfig.string?(row, "image_name") || distro) : (ImageConfig.string?(config, "image_name") || image)
          ImageConfig.patterns(row).each { |pattern| tags << "#{registry}/#{name}:#{ImageConfig.tag(pattern, version, distro)}" }
        end
        tags.uniq!
      end
    end
  end
end
