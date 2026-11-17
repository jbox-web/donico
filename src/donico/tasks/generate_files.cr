require "../bakefile"
require "../config"
require "../env"
require "../image"
require "../matrix_file"

module Donico
  module Tasks
    # Writes the two generated files, the CI matrix and the bakefile, under
    # the project directory. Both are rendered before either is written: a
    # value that cannot be rendered then leaves the repository as it was,
    # instead of with a new matrix next to an old bakefile.
    class GenerateFiles
      MATRIX_PATH   = ".gitlab-ci/extends/.matrix.yml"
      BAKEFILE_PATH = "docker-bake.hcl"

      def initialize(@config : Config, @env : Env)
      end

      def run : Int32
        matrix = MatrixFile.render(@config)
        bakefile = Bakefile.render(Image.all(@config))

        write_all({MATRIX_PATH => matrix, BAKEFILE_PATH => bakefile})
        @env.stdout.puts "GitlabCI Matrix file generated"
        @env.stdout.puts "Bakefile generated"
        0
      end

      # Both files go through a temporary file of their own directory first,
      # then are renamed into place: a failure while writing leaves every
      # target untouched, and a failure while renaming puts back the targets
      # already replaced. Nothing is announced before all of it succeeded.
      private def write_all(files : Hash(String, String)) : Nil
        temporaries = {} of String => String
        replaced = [] of {String, String?}
        current = ""
        begin
          files.each do |relative, content|
            current = relative
            path = File.join(@env.dir, relative)
            Dir.mkdir_p(File.dirname(path))
            temporary = File.join(File.dirname(path), ".#{File.basename(path)}.donico-#{Process.pid}.tmp")
            temporaries[relative] = temporary
            File.write(temporary, content)
          end
          files.each_key do |relative|
            current = relative
            path = File.join(@env.dir, relative)
            previous = File.file?(path) ? File.read(path) : nil
            File.rename(temporaries[relative], path)
            replaced << {path, previous}
          end
        rescue error : File::Error
          temporaries.each_value { |temporary| File.delete?(temporary) rescue nil }
          replaced.each { |(path, previous)| restore(path, previous) }
          reason = error.os_error.try(&.message) || error.message
          raise EnvironmentError.new("cannot write #{current}: #{reason}")
        end
      end

      # Best effort: the target is already being reported as failed.
      private def restore(path : String, previous : String?) : Nil
        if previous
          File.write(path, previous)
        else
          File.delete?(path)
        end
      rescue File::Error
      end
    end
  end
end
