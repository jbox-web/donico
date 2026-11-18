require "../../spec_helper"

private def donico_yml : String
  <<-YAML
    registry: harbor.example.org/base
    image_name: traefik
    github_repo: traefik/traefik
    matrix:
      - version: "3.7.9"
        distro: trixie
        tags:
          - "%<version>s-%<distro>s"

    YAML
end

describe Donico::Fleet::Regenerate do
  it "writes the bakefile and the CI matrix of the repository and prints nothing" do
    with_project(donico_yml) do |env|
      outcome = Donico::Fleet::Regenerate.call(env)

      outcome.should eq({:ok, nil})
      File.exists?(File.join(env.dir, "docker-bake.hcl")).should be_true
      File.read(File.join(env.dir, ".gitlab-ci/extends/.matrix.yml")).should contain("3.7.9")
      env.stdout.to_s.should be_empty
      env.stderr.to_s.should be_empty
    end
  end

  it "fails with the message of donico when the configuration is refused" do
    with_tmp_dir do |dir|
      env = Donico::Env.new({} of String => String, dir, IO::Memory.new, IO::Memory.new, Time.utc)

      outcome = Donico::Fleet::Regenerate.call(env)

      outcome.should eq({:fail, "generate-files failed: donico.yml not found in #{dir}"})
    end
  end

  it "fails for an unquoted version donico refuses, and writes nothing" do
    with_project(donico_yml.sub(%("3.7.9"), "3.10")) do |env|
      outcome = Donico::Fleet::Regenerate.call(env)

      outcome[0].should eq :fail
      outcome[1].to_s.should start_with("generate-files failed: donico.yml")
      File.exists?(File.join(env.dir, "docker-bake.hcl")).should be_false
    end
  end
end
