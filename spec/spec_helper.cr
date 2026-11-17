require "spec"
require "file_utils"

# Every library file; src/donico.cr, the entry point, is left out.
require "../src/donico/**"
require "./support/*"

# Result of an in-process CLI run: exit code plus everything written to the
# two streams. The CLI never calls `exit` itself, which is what makes it
# drivable from a spec without spawning the binary.
record CliRun, code : Int32, stdout : String, stderr : String

# Runs the CLI as if launched from `dir`, without changing the process working
# directory (specs may run on several threads).
def run_cli_in(dir : String, args : Array(String)) : CliRun
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = Donico::CLI.new(stdout, stderr, dir).run(args)
  CliRun.new(code, stdout.to_s, stderr.to_s)
end

# Yields an empty temporary directory, removed afterwards: a project directory
# without a donico.yml.
def with_tmp_dir(& : String ->) : Nil
  dir = File.join(Dir.tempdir, "donico-spec-#{Process.pid}-#{Random::Secure.hex(4)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end
