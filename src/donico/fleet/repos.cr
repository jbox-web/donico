require "./manifest"
require "../error"

module Donico
  module Fleet
    # The image repositories a fleet is made of: the names its manifest
    # declares, and which of them are actually cloned in the workspace.
    class Repos
      # Both are exposed because the units that act on the fleet need them: the
      # manifest for the per-image policies, the root to resolve the templates
      # a fleet ships alongside it.
      getter manifest : Manifest
      getter root : String

      # `root` is the directory the workspace is relative to, normally the
      # fleet's configuration repository. Passed explicitly so that specs need
      # no change of directory.
      def initialize(@manifest : Manifest, @root : String)
      end

      def all : Array(String)
        @manifest.images
      end

      def cloned : Array(String)
        all.select { |name| cloned?(name) }
      end

      def cloned?(name : String) : Bool
        Dir.exists?(path(name))
      end

      def path(name : String) : String
        File.join(workspace, name)
      end

      # expand_path rather than join so that a manifest declaring "." (a fleet
      # whose repositories sit at its own root) yields the root itself rather
      # than a path with a stray "/." in the middle, and so that an absolute
      # workspace is kept as it is.
      def workspace : String
        File.expand_path(@manifest.workspace, @root)
      end

      def clone_url(name : String) : String
        @manifest.clone_url(name)
      end

      # The repos a command should act on: the one named, or all of them. A
      # name outside the manifest is an error, not a silent no-op.
      def resolve(name : String?) : Array(String)
        wanted = name.to_s
        return all if wanted.empty?
        return [wanted] if all.includes?(wanted)

        raise UsageError.new("Unknown repository: #{wanted}")
      end
    end
  end
end
