require "../../spec_helper"

private MINIMAL = <<-YAML
  registry:  harbor.example.org/base
  group:     git@example.org:factory/images
  workspace: docker-images
  images:
    - ruby
    - nginx

  YAML

private WITH_POLICIES = <<-YAML
  registry:  harbor.example.org/base
  group:     git@example.org:factory/images
  workspace: docker-images
  images:
    - ruby
    - commitlint:  { check_versions: false }
    - icinga2:     { constrain: "2.15" }
    - debian-jbox: { bump_donico: false }

  YAML

private def manifest_error(yaml : String?, & : Donico::Fleet::Manifest -> Nil) : String
  with_fleet(yaml) do |env|
    yield Donico::Fleet::Manifest.load(env)
  rescue e : Donico::ManifestError
    return e.message.to_s
  end
  fail "expected a ManifestError"
end

private def manifest_error(yaml : String?) : String
  manifest_error(yaml) { }
end

describe Donico::Fleet::Manifest do
  describe "the fleet settings" do
    it "reads the registry, the group and the workspace" do
      with_fleet(MINIMAL) do |env|
        manifest = Donico::Fleet::Manifest.load(env)
        manifest.registry.should eq "harbor.example.org/base"
        manifest.group.should eq "git@example.org:factory/images"
        manifest.workspace.should eq "docker-images"
      end
    end

    it "builds a clone URL from the group" do
      with_fleet(MINIMAL) do |env|
        Donico::Fleet::Manifest.load(env).clone_url("ruby").should eq "git@example.org:factory/images/ruby.git"
      end
    end
  end

  describe "the image list" do
    it "accepts bare names, sorted" do
      with_fleet(MINIMAL) do |env|
        Donico::Fleet::Manifest.load(env).images.should eq ["nginx", "ruby"]
      end
    end

    it "sorts them whatever the order of the file" do
      yaml = MINIMAL.sub("- ruby\n  - nginx", "- zeta\n  - alpha\n  - mid")
      with_fleet(yaml) do |env|
        Donico::Fleet::Manifest.load(env).images.should eq ["alpha", "mid", "zeta"]
      end
    end

    it "accepts a name carrying options" do
      with_fleet("#{MINIMAL}  - icinga2: { constrain: \"2.15\" }\n") do |env|
        Donico::Fleet::Manifest.load(env).images.should contain "icinga2"
      end
    end

    it "accepts a name whose options are left blank" do
      with_fleet("#{MINIMAL}  - crystal:\n") do |env|
        manifest = Donico::Fleet::Manifest.load(env)
        manifest.images.should contain "crystal"
        manifest.check_versions?("crystal").should be_true
      end
    end
  end

  describe "the per-image policies" do
    it "defaults to checking versions and bumping donico" do
      with_fleet(WITH_POLICIES) do |env|
        manifest = Donico::Fleet::Manifest.load(env)
        manifest.check_versions?("ruby").should be_true
        manifest.bump_donico?("ruby").should be_true
        manifest.pinned?("ruby").should be_false
        manifest.constraint("ruby").should be_nil
      end
    end

    it "honours check_versions" do
      with_fleet(WITH_POLICIES) do |env|
        Donico::Fleet::Manifest.load(env).check_versions?("commitlint").should be_false
      end
    end

    it "honours bump_donico" do
      with_fleet(WITH_POLICIES) do |env|
        Donico::Fleet::Manifest.load(env).bump_donico?("debian-jbox").should be_false
      end
    end

    it "honours constrain" do
      with_fleet(WITH_POLICIES) do |env|
        Donico::Fleet::Manifest.load(env).constraint("icinga2").should eq "2.15"
      end
    end

    it "honours pinned, which still lets the image be scanned" do
      with_fleet("#{MINIMAL}  - traefik: { pinned: true }\n") do |env|
        manifest = Donico::Fleet::Manifest.load(env)
        manifest.pinned?("traefik").should be_true
        manifest.check_versions?("traefik").should be_true
        manifest.pinned?("ruby").should be_false
      end
    end

    it "honours an explicit check_versions: true and bump_donico: true" do
      with_fleet("#{MINIMAL}  - x: { check_versions: true, bump_donico: true }\n") do |env|
        manifest = Donico::Fleet::Manifest.load(env)
        manifest.check_versions?("x").should be_true
        manifest.bump_donico?("x").should be_true
      end
    end

    it "treats an undeclared name as having the default policies" do
      with_fleet(MINIMAL) do |env|
        manifest = Donico::Fleet::Manifest.load(env)
        manifest.check_versions?("nope").should be_true
        manifest.constraint("nope").should be_nil
      end
    end

    it "refuses an unknown policy key, naming it and the known ones" do
      manifest_error("#{MINIMAL}  - ruby: { colour: red }\n").should eq(
        "donico-manager.yml: ruby declares unknown policy colour. Known: check_versions, bump_donico, constrain, pinned.")
    end

    it "names every unknown policy at once" do
      manifest_error("#{MINIMAL}  - ruby: { constraint: \"3.4\", skip: true }\n").should eq(
        "donico-manager.yml: ruby declares unknown policies constraint, skip. Known: check_versions, bump_donico, constrain, pinned.")
    end

    it "refuses a policy of the wrong type" do
      manifest_error("#{MINIMAL}  - ruby: { pinned: yes please }\n").should eq(
        "donico-manager.yml: pinned must be a boolean.")
    end

    it "refuses a boolean policy that is a string" do
      manifest_error("#{MINIMAL}  - ruby: { check_versions: \"no\" }\n").should eq(
        "donico-manager.yml: check_versions must be a boolean.")
    end
  end

  describe "refusing a manifest it cannot work from" do
    it "says the manifest is not found" do
      with_fleet(nil) do |env|
        expect_raises(Donico::ManifestError, "donico-manager.yml not found. donico-manager runs from the root of a fleet's configuration repository.") do
          Donico::Fleet::Manifest.load(env)
        end
      end
    end

    it "refuses an empty file" do
      manifest_error("").should eq "donico-manager.yml is empty."
    end

    it "refuses a file holding only a comment" do
      manifest_error("# nothing\n").should eq "donico-manager.yml is empty."
    end

    it "names the missing key" do
      yaml = MINIMAL.lines(chomp: false).reject(&.starts_with?("group:")).join
      manifest_error(yaml).should eq "donico-manager.yml is missing: group."
    end

    it "names every missing key at once, in the order registry, group, workspace, images" do
      manifest_error("browse_url: x\n").should eq "donico-manager.yml is missing: registry, group, workspace, images."
    end

    it "names the missing images key" do
      yaml = MINIMAL.sub("images:\n  - ruby\n  - nginx\n", "")
      manifest_error(yaml).should eq "donico-manager.yml is missing: images."
    end

    it "refuses an empty image list" do
      manifest_error(MINIMAL.sub("  - ruby\n  - nginx\n", "  []\n")).should eq "donico-manager.yml declares no images."
    end

    it "refuses an images key that is not a list" do
      manifest_error(MINIMAL.sub("images:\n  - ruby\n  - nginx\n", "images: ruby\n")).should eq "donico-manager.yml declares no images."
    end

    it "refuses an entry that is neither a name nor a name with options" do
      manifest_error("#{MINIMAL}  - 42\n").should eq(
        "donico-manager.yml: images[2] is neither an image name nor a name with options.")
    end

    ["3.4", "true"].each do |scalar|
      it "refuses options that are a bare #{scalar} rather than a mapping" do
        manifest_error("#{MINIMAL}  - ruby: #{scalar}\n").should eq(
          "donico-manager.yml: images[2] is neither an image name nor a name with options.")
      end
    end

    it "refuses an entry carrying more than one name" do
      manifest_error("#{MINIMAL}  - { ruby: {}, nginx: {} }\n").should eq(
        "donico-manager.yml: images[2] is neither an image name nor a name with options.")
    end

    it "refuses a file that is not YAML, with one line and no backtrace" do
      message = manifest_error("registry: [unclosed\n")
      message.should start_with "donico-manager.yml: invalid YAML: "
      message.should_not contain "\n"
    end

    it "refuses a top level that is not a mapping" do
      manifest_error("- a\n- b\n").should eq "donico-manager.yml: expected a mapping at the top level."
    end
  end

  describe "values of the wrong type" do
    it "refuses a categories key that is a string" do
      manifest_error("#{MINIMAL}categories: tools\n").should eq "donico-manager.yml: categories must be a list of strings."
    end

    it "refuses a categories list holding a non-string" do
      manifest_error("#{MINIMAL}categories: [tools, {a: b}]\n").should eq "donico-manager.yml: categories must be a list of strings."
    end

    it "refuses debian_images that is a string" do
      manifest_error("#{MINIMAL}debian_images: debian-base\n").should eq "donico-manager.yml: debian_images must be a list of strings."
    end

    it "refuses a registries key that is a string" do
      manifest_error("#{MINIMAL}registries: x\n").should eq "donico-manager.yml: registries must be a mapping."
    end

    it "refuses a registries list" do
      manifest_error("#{MINIMAL}registries: [x]\n").should eq "donico-manager.yml: registries must be a mapping."
    end

    it "refuses a registries entry that is not a string" do
      manifest_error("#{MINIMAL}registries: { a: [x] }\n").should eq "donico-manager.yml: registries must be a mapping."
    end

    it "refuses an unquoted constrain" do
      manifest_error("#{MINIMAL}  - ruby: { constrain: 3.9 }\n").should eq "donico-manager.yml: constrain must be a string."
    end

    %w[registry group workspace browse_url ci_config_url heritage_output].each do |key|
      it "refuses a #{key} that is not a string" do
        yaml = if MINIMAL.includes?("#{key}:")
                 MINIMAL.lines(chomp: false).map { |line| line.starts_with?("#{key}:") ? "#{key}: [a]\n" : line }.join
               else
                 "#{MINIMAL}#{key}: [a]\n"
               end
        manifest_error(yaml).should eq "donico-manager.yml: #{key} must be a string."
      end
    end
  end

  describe "the optional settings" do
    it "accepts a commit_linter without exposing it" do
      with_fleet("#{MINIMAL}commit_linter: harbor.example.org/base/commitlint:1.2.3\n") do |env|
        manifest = Donico::Fleet::Manifest.load(env)
        manifest.registry.should eq "harbor.example.org/base"
        manifest.responds_to?(:commit_linter).should be_false
      end
    end

    it "defaults the documentation settings" do
      with_fleet(MINIMAL) do |env|
        manifest = Donico::Fleet::Manifest.load(env)
        manifest.categories.should eq([] of String)
        manifest.debian_images.should eq([] of String)
        manifest.registries.should eq({} of String => String)
        manifest.browse_url.should be_nil
        manifest.ci_config_url.should be_nil
        manifest.heritage_output.should eq "doc/image-heritage.md"
      end
    end

    it "takes the fleet for a GitLab one, built by images.yml, unless it says otherwise" do
      with_fleet(MINIMAL) do |env|
        manifest = Donico::Fleet::Manifest.load(env)
        manifest.forge.should eq "gitlab"
        manifest.ci_workflow.should eq "images.yml"
      end
    end

    it "reads the forge and the CI workflow a fleet declares" do
      with_fleet("#{MINIMAL}forge: github\nci_workflow: build.yml\n") do |env|
        manifest = Donico::Fleet::Manifest.load(env)
        manifest.forge.should eq "github"
        manifest.ci_workflow.should eq "build.yml"
      end
    end

    it "refuses a forge it does not know, naming the ones it does" do
      manifest_error("#{MINIMAL}forge: bitbucket\n").should eq "donico-manager.yml: forge must be gitlab or github, got: bitbucket."
    end

    it "refuses a ci_workflow that is not a file name" do
      manifest_error("#{MINIMAL}ci_workflow: ci/build.yml\n").should eq "donico-manager.yml: ci_workflow must be the file name of a workflow, got: ci/build.yml."
    end

    it "reads the documentation settings a fleet declares" do
      extra = <<-YAML
        browse_url:      https://gitlab.example.org/factory/images
        ci_config_url:   https://gitlab.example.org/factory/-/settings/ci_cd
        heritage_output: doc/tree.md
        debian_images:   [debian-base]
        categories:      [distro, tools]
        YAML

      with_fleet("#{MINIMAL}#{extra}\n") do |env|
        manifest = Donico::Fleet::Manifest.load(env)
        manifest.browse_url.should eq "https://gitlab.example.org/factory/images"
        manifest.ci_config_url.should eq "https://gitlab.example.org/factory/-/settings/ci_cd"
        manifest.heritage_output.should eq "doc/tree.md"
        manifest.debian_images.should eq ["debian-base"]
        manifest.categories.should eq ["distro", "tools"]
      end
    end

    it "exposes the registries the heritage tree walks" do
      with_fleet("#{MINIMAL}registries:\n  debian_jbox: harbor.example.org/debian\n") do |env|
        Donico::Fleet::Manifest.load(env).registries["debian_jbox"].should eq "harbor.example.org/debian"
      end
    end

    it "resolves a merge key the way donico.yml does" do
      yaml = <<-YAML
        defaults: &d
          registry: harbor.example.org/base
          group: g
        <<: *d
        workspace: w
        images: [a]

        YAML
      with_fleet(yaml) do |env|
        Donico::Fleet::Manifest.load(env).registry.should eq "harbor.example.org/base"
      end
    end
  end
end
