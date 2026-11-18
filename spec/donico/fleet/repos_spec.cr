require "../../spec_helper"

private def fleet_yaml(workspace : String = "docker-images", images : String = "- traefik\n  - grafana\n  - ruby") : String
  <<-YAML
    registry:  harbor.example.org/base
    group:     git@example.org:factory/images
    workspace: #{workspace}
    images:
      #{images}

    YAML
end

private def repos_for(env : Donico::Env) : Donico::Fleet::Repos
  Donico::Fleet::Repos.new(Donico::Fleet::Manifest.load(env), env.dir)
end

private def clone(env : Donico::Env, *names : String) : Nil
  names.each { |name| Dir.mkdir_p(File.join(env.dir, "docker-images", name)) }
end

describe Donico::Fleet::Repos do
  describe "#all" do
    it "reads the declared names, sorted" do
      with_fleet(fleet_yaml) { |env| repos_for(env).all.should eq ["grafana", "ruby", "traefik"] }
    end
  end

  describe "#manifest and #root" do
    it "expose what they were built from" do
      with_fleet(fleet_yaml) do |env|
        repos = repos_for(env)
        repos.root.should eq env.dir
        repos.manifest.registry.should eq "harbor.example.org/base"
      end
    end
  end

  describe "#cloned" do
    it "keeps only the repos present in the workspace" do
      with_fleet(fleet_yaml) do |env|
        clone(env, "traefik", "ruby")
        repos_for(env).cloned.should eq ["ruby", "traefik"]
      end
    end

    it "is empty when nothing is cloned" do
      with_fleet(fleet_yaml) { |env| repos_for(env).cloned.should eq([] of String) }
    end

    it "ignores a directory nobody declared" do
      with_fleet(fleet_yaml) do |env|
        clone(env, "traefik", "surprise")
        repos_for(env).cloned.should eq ["traefik"]
      end
    end
  end

  describe "#cloned?" do
    it "reports whether a repo is in the workspace" do
      with_fleet(fleet_yaml) do |env|
        clone(env, "traefik")
        repos = repos_for(env)
        repos.cloned?("traefik").should be_true
        repos.cloned?("grafana").should be_false
      end
    end

    it "is false for a plain file of that name" do
      with_fleet(fleet_yaml, {"docker-images/ruby" => "x"}) do |env|
        repos_for(env).cloned?("ruby").should be_false
      end
    end
  end

  describe "#path and #workspace" do
    it "gives the repo's directory inside a relative workspace" do
      with_fleet(fleet_yaml) do |env|
        repos = repos_for(env)
        repos.workspace.should eq File.join(env.dir, "docker-images")
        repos.path("traefik").should eq File.join(env.dir, "docker-images", "traefik")
      end
    end

    it "gives the root itself for a workspace of ." do
      with_fleet(fleet_yaml(workspace: ".")) do |env|
        repos = repos_for(env)
        repos.workspace.should eq env.dir
        repos.path("traefik").should eq File.join(env.dir, "traefik")
      end
    end

    it "keeps an absolute workspace as it is" do
      with_fleet(fleet_yaml(workspace: "/srv/fleet/images")) do |env|
        repos = repos_for(env)
        repos.workspace.should eq "/srv/fleet/images"
        repos.path("ruby").should eq "/srv/fleet/images/ruby"
      end
    end

    it "resolves a workspace beside the configuration repository" do
      with_fleet(fleet_yaml(workspace: "../docker-images")) do |env|
        repos = repos_for(env)
        repos.workspace.should eq File.join(File.dirname(env.dir), "docker-images")
        repos.path("ruby").should eq File.join(File.dirname(env.dir), "docker-images", "ruby")
      end
    end

    it "finds the clones of a workspace of ." do
      with_fleet(fleet_yaml(workspace: ".")) do |env|
        Dir.mkdir_p(File.join(env.dir, "ruby"))
        repos_for(env).cloned.should eq ["ruby"]
      end
    end
  end

  describe "#clone_url" do
    it "builds the SSH URL from the group the manifest declares" do
      with_fleet(fleet_yaml) do |env|
        repos_for(env).clone_url("traefik").should eq "git@example.org:factory/images/traefik.git"
      end
    end
  end

  describe "#resolve" do
    it "returns every repo when none is named" do
      with_fleet(fleet_yaml) { |env| repos_for(env).resolve(nil).should eq ["grafana", "ruby", "traefik"] }
    end

    it "returns the single named repo" do
      with_fleet(fleet_yaml) { |env| repos_for(env).resolve("traefik").should eq ["traefik"] }
    end

    it "treats an empty name as none" do
      with_fleet(fleet_yaml) { |env| repos_for(env).resolve("").should eq ["grafana", "ruby", "traefik"] }
    end

    it "raises a usage error on a name the manifest does not declare" do
      with_fleet(fleet_yaml) do |env|
        expect_raises(Donico::UsageError, "Unknown repository: nope") { repos_for(env).resolve("nope") }
      end
    end
  end
end
