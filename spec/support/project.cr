require "file_utils"

require "../../src/donico/env"

# Yields an `Env` for a temporary project directory holding `donico.yml` with
# the given text, plus any other file (relative path => content). The clock is
# fixed and the variables are exactly the ones passed, never the process
# environment, so a spec cannot depend on the machine it runs on. The
# directory is removed afterwards, whatever the block does.
def with_project(yaml : String,
                 files : Hash(String, String) = {} of String => String,
                 vars : Hash(String, String) = {} of String => String,
                 now : Time = Time.local(2026, 7, 31, 23, 59, 59, location: Time::Location::UTC),
                 & : Donico::Env ->) : Nil
  dir = File.join(Dir.tempdir, "donico-project-#{Process.pid}-#{Random::Secure.hex(4)}")
  Dir.mkdir_p(dir)
  begin
    File.write(File.join(dir, "donico.yml"), yaml)
    files.each do |path, content|
      full = File.join(dir, path)
      Dir.mkdir_p(File.dirname(full))
      File.write(full, content)
    end
    yield Donico::Env.new(vars, dir, IO::Memory.new, IO::Memory.new, now)
  ensure
    FileUtils.rm_rf(dir)
  end
end
