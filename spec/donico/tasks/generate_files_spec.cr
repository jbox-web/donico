require "../../spec_helper"

private FIXTURES    = File.join(__DIR__, "..", "..", "fixtures")
private SIMPLE_YAML = "registry: r\nimage_name: foo\nmatrix:\n  - {version: \"1\", distro: a}\n"

describe Donico::Tasks::GenerateFiles do
  it "writes the matrix file and the bakefile under the project directory" do
    yaml = File.read(File.join(FIXTURES, "bake", "multiple_dockerfiles.yml"))
    with_project(yaml, vars: {"CI_COMMIT_TIMESTAMP" => "2026-07-31T00:00:00Z"}) do |env|
      config = Donico::Config.load(env)

      Donico::Tasks::GenerateFiles.new(config, env).run.should eq 0

      matrix = File.read(File.join(env.dir, ".gitlab-ci", "extends", ".matrix.yml"))
      matrix.should eq File.read(File.join(FIXTURES, "generated", "matrix", "multiple_dockerfiles.yml"))
      bake = File.read(File.join(env.dir, "docker-bake.hcl"))
      bake.should eq File.read(File.join(FIXTURES, "generated", "bakefile", "multiple_dockerfiles.txt"))
      env.stdout.to_s.should eq "GitlabCI Matrix file generated\nBakefile generated\n"
    end
  end

  it "writes neither file when the bakefile cannot be rendered" do
    yaml = "registry: r\nimage_name: foo\nmatrix:\n  - {version: \"1\", distro: a}\n"
    with_project(yaml, vars: {"CI_COMMIT_TIMESTAMP" => "nonsense"}) do |env|
      config = Donico::Config.load(env)

      expect_raises(Donico::ConfigError, %(CI_COMMIT_TIMESTAMP is not an ISO 8601 timestamp: "nonsense")) do
        Donico::Tasks::GenerateFiles.new(config, env).run
      end

      File.exists?(File.join(env.dir, ".gitlab-ci")).should be_false
      File.exists?(File.join(env.dir, "docker-bake.hcl")).should be_false
    end
  end

  it "reports a directory that cannot be written, leaving nothing announced" do
    with_project(SIMPLE_YAML) do |env|
      extends = File.join(env.dir, ".gitlab-ci", "extends")
      Dir.mkdir_p(extends)
      File.chmod(extends, 0o555)
      begin
        # Root writes anywhere: the case cannot be produced there.
        pending!("directory stays writable (running as root)") if File::Info.writable?(extends)
        config = Donico::Config.load(env)

        expect_raises(Donico::EnvironmentError, "cannot write .gitlab-ci/extends/.matrix.yml: Permission denied") do
          Donico::Tasks::GenerateFiles.new(config, env).run
        end

        env.stdout.to_s.should eq ""
        File.exists?(File.join(env.dir, "docker-bake.hcl")).should be_false
        Dir.children(extends).should be_empty
      ensure
        File.chmod(extends, 0o755)
      end
    end
  end

  it "reports a .gitlab-ci that is a file, and writes nothing" do
    with_project(SIMPLE_YAML, files: {".gitlab-ci" => "not a directory\n"}) do |env|
      config = Donico::Config.load(env)

      error = expect_raises(Donico::EnvironmentError) { Donico::Tasks::GenerateFiles.new(config, env).run }

      error.message.to_s.should start_with "cannot write .gitlab-ci/extends/.matrix.yml: "
      env.stdout.to_s.should eq ""
      Dir.children(env.dir).sort.should eq [".gitlab-ci", "donico.yml"]
    end
  end

  it "replaces two files that exist, leaving no temporary file behind" do
    with_project(SIMPLE_YAML, files: {".gitlab-ci/extends/.matrix.yml" => "old\n", "docker-bake.hcl" => "old\n"}) do |env|
      config = Donico::Config.load(env)

      Donico::Tasks::GenerateFiles.new(config, env).run.should eq 0

      File.read(File.join(env.dir, "docker-bake.hcl")).should start_with "# !!! THIS IS A GENERATED FILE !!!"
      File.read(File.join(env.dir, ".gitlab-ci", "extends", ".matrix.yml")).should start_with "# !!! THIS IS A GENERATED FILE !!!"
      Dir.children(File.join(env.dir, ".gitlab-ci", "extends")).should eq [".matrix.yml"]
      Dir.children(env.dir).sort.should eq [".gitlab-ci", "docker-bake.hcl", "donico.yml"]
    end
  end

  it "removes the first file when the second cannot be put in place" do
    with_project(SIMPLE_YAML) do |env|
      # A directory where the bakefile goes: the rename onto it fails.
      Dir.mkdir_p(File.join(env.dir, "docker-bake.hcl"))
      config = Donico::Config.load(env)

      expect_raises(Donico::EnvironmentError, "cannot write docker-bake.hcl: Is a directory") do
        Donico::Tasks::GenerateFiles.new(config, env).run
      end

      env.stdout.to_s.should eq ""
      File.exists?(File.join(env.dir, ".gitlab-ci", "extends", ".matrix.yml")).should be_false
      Dir.children(File.join(env.dir, ".gitlab-ci", "extends")).should be_empty
      Dir.children(env.dir).sort.should eq [".gitlab-ci", "docker-bake.hcl", "donico.yml"]
    end
  end

  it "restores the previous first file when the second cannot be put in place" do
    with_project(SIMPLE_YAML, files: {".gitlab-ci/extends/.matrix.yml" => "old\n"}) do |env|
      Dir.mkdir_p(File.join(env.dir, "docker-bake.hcl"))
      config = Donico::Config.load(env)

      expect_raises(Donico::EnvironmentError, "cannot write docker-bake.hcl") do
        Donico::Tasks::GenerateFiles.new(config, env).run
      end

      File.read(File.join(env.dir, ".gitlab-ci", "extends", ".matrix.yml")).should eq "old\n"
    end
  end
end
