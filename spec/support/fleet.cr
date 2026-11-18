require "file_utils"

require "../../src/donico/env"

# Yields an `Env` for a temporary configuration repository holding
# `donico-manager.yml` with the given text, plus any other file (relative path
# => content). Modelled on `with_project`: fixed clock, exactly the variables
# passed, directory removed afterwards whatever the block does. `manifest_yaml`
# nil leaves the manifest out.
def with_fleet(manifest_yaml : String?,
               files : Hash(String, String) = {} of String => String,
               vars : Hash(String, String) = {} of String => String,
               now : Time = Time.local(2026, 7, 31, 23, 59, 59, location: Time::Location::UTC),
               & : Donico::Env ->) : Nil
  dir = File.join(Dir.tempdir, "donico-fleet-#{Process.pid}-#{Random::Secure.hex(4)}")
  Dir.mkdir_p(dir)
  begin
    File.write(File.join(dir, "donico-manager.yml"), manifest_yaml) if manifest_yaml
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

# The fixture fleet (spec/fixtures/fleet), the way `with_fleet` hands out a
# temporary configuration repository: a copy without its `expected/` files,
# removed afterwards, so that a generator can write into it. Nothing is ever
# written into spec/fixtures/.
def with_fixture_fleet(vars : Hash(String, String) = {} of String => String,
                       now : Time = Time.local(2026, 7, 31, 23, 59, 59, location: Time::Location::UTC),
                       & : Donico::Env ->) : Nil
  source = File.expand_path("../fixtures/fleet", __DIR__)
  dir = File.join(Dir.tempdir, "donico-fleet-fixture-#{Process.pid}-#{Random::Secure.hex(4)}")
  begin
    FileUtils.cp_r(source, dir)
    FileUtils.rm_rf(File.join(dir, "expected"))
    FileUtils.rm_f(File.join(dir, "README.md"))
    yield Donico::Env.new(vars, dir, IO::Memory.new, IO::Memory.new, now)
  ensure
    FileUtils.rm_rf(dir)
  end
end

# A file of the fixture fleet's expected output, e.g. "README.md" or
# "docker-images/ruby/README.md".
def expected_fleet_file(path : String) : String
  File.read(File.join(File.expand_path("../fixtures/fleet/expected", __DIR__), path))
end

# The manifest and the repositories of a fleet directory, as the commands load them.
def fleet_repos_of(env : Donico::Env) : Donico::Fleet::Repos
  Donico::Fleet::Repos.new(Donico::Fleet::Manifest.load(env), env.dir)
end
