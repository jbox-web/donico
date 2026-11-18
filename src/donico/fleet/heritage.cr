require "../env"
require "./repos"

module Donico
  module Fleet
    # Renders the inheritance tree of a fleet, read from the FROM lines of its
    # Dockerfiles, and writes it where the manifest says.
    #
    # The registry prefixes it matches on come from the manifest: they name
    # where a fleet publishes, which is the one thing that differs. The
    # rendering itself (the tree, the wording, the note about cascading
    # rebuilds) is the organisation's format and stays here, so every fleet
    # documents alike. Its texts and the two labels `debian-jbox` and
    # `debian-base` are the Ruby gem's, verbatim.
    class Heritage
      # The virtual root of the debian images: it has no standard Dockerfile of
      # its own to read.
      DEBIAN_BASE = "debian-base"

      def initialize(@repos : Repos, @env : Env)
        @output = File.join(@repos.root, @repos.manifest.heritage_output)
      end

      def run : Nil
        images = @repos.all
        parents = build_parents(images)
        Dir.mkdir_p(File.dirname(@output))
        File.write(@output, render(images, parents))
        @env.stdout.puts "Written #{@output}"
      end

      # The parent of each cloned image: its classified base, or nil when no
      # Dockerfile (or no FROM line) could be read. An image that is not cloned
      # has no entry at all.
      private def build_parents(images : Array(String)) : Hash(String, String?)
        parents = {} of String => String?
        images.each do |image|
          path = @repos.path(image)
          next unless Dir.exists?(path)

          dockerfile = find_dockerfile(path)
          parents[image] = dockerfile ? extract_parent(dockerfile) : nil
        end
        parents
      end

      # The root Dockerfile, else the first of dockerfiles/**/. Crystal's glob
      # follows the file system's order, Ruby's sorts the entries of each
      # directory by name: sorting the path segments gives Ruby's order ("a"
      # before "a-b", where a plain sort of the strings puts "a-b" first).
      private def find_dockerfile(path : String) : String?
        candidates = [File.join(path, "Dockerfile")] + Dir.glob("#{path}/dockerfiles/**/Dockerfile").sort_by(&.split('/'))
        candidates.find { |file| File.exists?(file) }
      end

      private def extract_parent(dockerfile : String) : String?
        from_line = File.read_lines(dockerfile).find(&.strip.matches?(/\AFROM\s+/i))
        return unless from_line

        ref = from_line.strip
          .sub(/\AFROM\s+/i, "")
          .split(/\s+AS\s+/i, remove_empty: false).first
          .strip
          .gsub(/\$\{[^}]+\}/, "")
        # Drop the tag, then a trailing / or -.
        ref = ref.partition(':')[0].gsub(/[\/-]+\z/, "")

        classify(ref)
      end

      # A registry the manifest does not declare must match nothing: an empty
      # prefix would match every reference and send every image under
      # debian-jbox, a parent absent from the list, which left the tree empty.
      private def under?(ref : String, registry : String) : Bool
        !registry.empty? && ref.starts_with?(registry)
      end

      private def classify(ref : String) : String
        base = "#{@repos.manifest.registry}/"
        return ref.lchop(base) if under?(ref, base)
        return "debian-jbox" if under?(ref, @repos.manifest.registries["debian_jbox"]?.to_s)
        return DEBIAN_BASE if under?(ref, @repos.manifest.registries["debian_base"]?.to_s)

        # Verbatim: rebuilt as host + last segment, the reference would drop
        # every segment in between (bitnami/minideb is not docker.io/minideb).
        "external:#{ref}"
      end

      # The generated file can sit at any depth the manifest asks for, so the
      # link back to the root is computed rather than written with a fixed
      # number of "../".
      private def back_to_root : String
        parts = File.dirname(@repos.manifest.heritage_output).split('/', remove_empty: false)
        # Ruby's split drops trailing empty fields.
        while parts.last? == ""
          parts.pop
        end
        "../" * parts.count { |part| part != "." }
      end

      private def external?(parents : Hash(String, String?), image : String) : Bool
        !!parents[image]?.try(&.starts_with?("external:"))
      end

      # Images whose base could not be read at all: not cloned, or cloned
      # without a readable FROM. Both are an absence of answer and not an
      # answer of absence. debian-base is excluded as it is displayed as a
      # virtual root.
      private def undetermined_images(images : Array(String), parents : Hash(String, String?)) : Array(String)
        images.select { |image| image != DEBIAN_BASE && parents[image]?.nil? }.sort!
      end

      private def render(images : Array(String), parents : Hash(String, String?)) : String
        undetermined = undetermined_images(images, parents)
        children = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }

        # "debian-base" need not be in the manifest: it is a virtual root.
        images.each do |image|
          parent = parents[image]?
          next if parent.nil? || parent.starts_with?("external:")

          children[parent] << image
        end
        children.each_value(&.sort!)

        # Real roots: images nobody claims as a child and whose base is known.
        # An image nobody cloned has no Dockerfile to read, so its parent is
        # nil for want of an answer, not because it has none.
        claimed = children.values.flatten.to_set
        roots = images.reject do |image|
          claimed.includes?(image) || external?(parents, image) || undetermined.includes?(image)
        end.sort!

        debian_base_kids = children[DEBIAN_BASE]
        roots.unshift(DEBIAN_BASE) unless debian_base_kids.empty?

        externals = images.select { |image| image != DEBIAN_BASE && external?(parents, image) }.sort!

        # Images caught in a FROM cycle claim each other as children, so none of
        # them is a root and the walk never reaches them.
        cyclic = images - reachable(roots, children, debian_base_kids) - externals - undetermined - [DEBIAN_BASE]

        lines = [] of String
        lines << "# Chaîne d'héritage des images"
        lines << ""
        lines << "← [CLAUDE.md](#{back_to_root}CLAUDE.md)"
        lines << ""
        lines << "**Description :** Arbre d'héritage des images — " \
                 "généré par `donico-manager heritage` depuis les lignes `FROM` des Dockerfiles. " \
                 "Ne pas éditer manuellement."
        lines << ""
        lines << "---"
        lines << ""
        render_tree(roots, children, debian_base_kids, lines)

        unless externals.empty?
          lines << "## Images avec base externe"
          lines << ""
          lines << "| Image | FROM |"
          lines << "|---|---|"
          externals.each do |image|
            lines << "| #{image} | `#{parents[image].to_s.lchop("external:")}` |"
          end
          lines << ""
        end

        # Said out loud rather than left out: a tree that omits images cannot be
        # told from a flat hierarchy.
        unless cyclic.empty?
          lines << "## Images en cycle de FROM"
          lines << ""
          lines << "Ces images dérivent les unes des autres en boucle, elles ne peuvent donc " \
                   "apparaître dans aucun arbre — corrigez leurs lignes `FROM`."
          lines << ""
          lines << "| Image | FROM |"
          lines << "|---|---|"
          cyclic.sort.each { |image| lines << "| #{image} | `#{parents[image]?}` |" }
          lines << ""
        end

        unless undetermined.empty?
          lines << "## Images à base indéterminée"
          lines << ""
          lines << "Déclarées au manifest, mais sans Dockerfile lisible dans le workspace — " \
                   "clonez-les puis relancez pour les voir prendre leur place dans l'arbre."
          lines << ""
          lines << "| Image |"
          lines << "|---|"
          undetermined.each { |image| lines << "| #{image} |" }
          lines << ""
        end

        lines.join('\n')
      end

      # A fleet can have no internal hierarchy at all, and an empty fenced
      # block reads as a rendering failure rather than as a description.
      private def render_tree(roots : Array(String), children : Hash(String, Array(String)),
                              debian_base_kids : Array(String), lines : Array(String)) : Nil
        return if roots.empty?

        lines << "## Arbre"
        lines << ""
        lines << "```"

        roots.each do |root|
          if root == DEBIAN_BASE
            lines << "debian-base  (pipeline debuerreotype — pas de Dockerfile standard)"
            render_children(debian_base_kids, children, lines, "", [] of String)
          else
            lines << root
            render_children(children[root], children, lines, "", [] of String)
          end
        end

        lines << "```"
        lines << ""
        lines << "**Note :** toute mise à jour d'une image entraîne un rebuild en cascade " \
                 "de toutes les images indentées en dessous d'elle."
        lines << ""
      end

      # Everything the tree walk prints, roots included. What is left over is in
      # a cycle: claimed as someone's child, but reachable from no root.
      private def reachable(roots : Array(String), children : Hash(String, Array(String)),
                            debian_base_kids : Array(String)) : Array(String)
        seen = [] of String
        queue = roots.flat_map { |root| root == DEBIAN_BASE ? debian_base_kids : [root] } + roots

        until queue.empty?
          node = queue.shift
          next if seen.includes?(node)

          seen << node
          queue.concat(children[node])
        end
        seen
      end

      # `seen` guards against a FROM cycle: `render` lists cyclic images apart
      # rather than walking into them, but the recursion is not the place to
      # rely on a caller having filtered its input.
      private def render_children(kids : Array(String), children : Hash(String, Array(String)),
                                  lines : Array(String), prefix : String, seen : Array(String)) : Nil
        kids.each_with_index do |child, index|
          next if seen.includes?(child)

          last = index == kids.size - 1
          lines << "#{prefix}#{last ? "└── " : "├── "}#{child}"
          render_children(children[child], children, lines, prefix + (last ? "    " : "│   "), seen + [child])
        end
      end
    end
  end
end
