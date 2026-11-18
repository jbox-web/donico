require "../../spec_helper"

private FIXTURE_IMAGES = %w[alloy debian-base debuerreotype nocategory ruby traefik]

private def image_readme_of(env : Donico::Env, image : String) : String
  File.read(File.join(env.dir, "docker-images", image, "README.md"))
end

private def image_readmes_for(env : Donico::Env, repo : String? = nil) : Nil
  Donico::Fleet::ImageReadme.new(fleet_repos_of(env), env).run(repo)
end

private def written(env : Donico::Env, image : String) : String
  "  updated #{File.join(env.dir, "docker-images", image, "README.md")}"
end

private def overwrite_image(env : Donico::Env, image : String, file : String, text : String) : Nil
  File.write(File.join(env.dir, "docker-images", image, file), text)
end

describe Donico::Fleet::ImageReadme do
  FIXTURE_IMAGES.each do |image|
    it "writes the README the gem writes for #{image}" do
      with_fixture_fleet do |env|
        image_readmes_for(env)

        image_readme_of(env, image).should eq expected_fleet_file("docker-images/#{image}/README.md")
      end
    end
  end

  it "narrates each image in the manifest order, then the count" do
    with_fixture_fleet do |env|
      image_readmes_for(env)

      env.stdout.to_s.should eq [
        "  skip absent (not cloned)",
        written(env, "alloy"),
        written(env, "debian-base"),
        written(env, "debuerreotype"),
        written(env, "nocategory"),
        written(env, "ruby"),
        written(env, "traefik"),
        "",
        "Done! 6 README(s) updated, 1 skipped.",
      ].join('\n') + "\n"
    end
  end

  it "writes nothing for an image that is not cloned" do
    with_fixture_fleet do |env|
      image_readmes_for(env)

      Dir.exists?(File.join(env.dir, "docker-images", "absent")).should be_false
    end
  end

  # The root README names the directory and the image's own registry, this one
  # the image_name and falls back on the manifest's registry: on purpose.
  it "names the image after its image_name, and falls back on the manifest's registry" do
    with_fixture_fleet do |env|
      image_readmes_for(env)

      image_readme_of(env, "alloy").should start_with "# grafana-alloy\n"
      image_readme_of(env, "alloy").should contain "- `registry.example.net/other/grafana-alloy:1.9.2`\n"
      image_readme_of(env, "nocategory").should contain "- `harbor.example.org/base/nocategory:1.0.0`\n"
    end
  end

  it "names the tags of a debian image after the image_name of their row" do
    with_fixture_fleet do |env|
      image_readmes_for(env)

      image_readme_of(env, "debian-base").should contain "- `harbor.example.org/base/debian-bookworm:12`\n"
    end
  end

  it "falls back on the distro for a debian image row without image_name" do
    with_fixture_fleet do |env|
      overwrite_image(env, "debian-base", "donico.yml", "registry: harbor.example.org/base\nmatrix:\n  - version: \"13\"\n    distro: trixie\n")
      image_readmes_for(env)

      image_readme_of(env, "debian-base").should contain "- `harbor.example.org/base/trixie:13`\n"
    end
  end

  it "reads a danico.yml" do
    with_fixture_fleet do |env|
      image_readmes_for(env)

      image_readme_of(env, "debuerreotype").should start_with "# debuerreotype\n"
    end
  end

  it "prints an unquoted 3.10 as the YAML parser reads it" do
    with_fixture_fleet do |env|
      image_readmes_for(env)

      image_readme_of(env, "ruby").should contain "FROM harbor.example.org/base/ruby:3.1\n"
    end
  end

  it "replaces the version and distro of a tag pattern and leaves anything else as written" do
    with_fixture_fleet do |env|
      overwrite_image(env, "ruby", "donico.yml", <<-YAML)
        registry: harbor.example.org/base
        matrix:
          - version: "1.0"
            distro: trixie
            tags: ["%<version>s-%<distro>s-%<timestamp>s-%%-%d"]
        YAML
      image_readmes_for(env, "ruby")

      image_readme_of(env, "ruby").should contain "- `harbor.example.org/base/ruby:1.0-trixie-%<timestamp>s-%%-%d`\n"
    end
  end

  it "lists a tag once when two rows produce it" do
    with_fixture_fleet do |env|
      overwrite_image(env, "ruby", "donico.yml", "registry: r\nmatrix:\n  - version: \"1\"\n  - version: \"1\"\n")
      image_readmes_for(env, "ruby")

      image_readme_of(env, "ruby").scan("- `r/ruby:1`\n").size.should eq 1
    end
  end

  it "leaves out the tags and the usage of a config without a matrix" do
    with_fixture_fleet do |env|
      overwrite_image(env, "ruby", "donico.yml", "description: Ruby\n")
      image_readmes_for(env, "ruby")

      image_readme_of(env, "ruby").should eq <<-README
        # ruby

        Ruby

        **Catégorie :** ?

        ## Commandes

        ```sh
        donico help
        ```

        ## CI Config

        Pour pousser les images Docker vers Harbor un token dédié a été créé, voir les [variables d'environnement du groupe](https://gitlab.example.org/groups/factory/-/settings/ci_cd) pour plus d'informations.

        README
    end
  end

  it "links the upstream repository only when the config names one" do
    with_fixture_fleet do |env|
      image_readmes_for(env)

      image_readme_of(env, "traefik").should contain "**Catégorie :** web · **Upstream :** [traefik/traefik](https://github.com/traefik/traefik)\n"
      image_readme_of(env, "ruby").should contain "**Catégorie :** web\n"
    end
  end

  it "runs through repos update-readme, and ends on the count" do
    with_fixture_fleet do |env|
      run = run_fleet_in(env.dir, ["repos", "update-readme"])

      run.code.should eq 0
      run.stdout.should eq [
        "  skip absent (not cloned)",
        written(env, "alloy"),
        written(env, "debian-base"),
        written(env, "debuerreotype"),
        written(env, "nocategory"),
        written(env, "ruby"),
        written(env, "traefik"),
        "",
        "Done! 6 README(s) updated, 1 skipped.",
      ].join('\n') + "\n"
      FIXTURE_IMAGES.each do |image|
        image_readme_of(env, image).should eq expected_fleet_file("docker-images/#{image}/README.md")
      end
    end
  end

  describe "with a repository name" do
    it "writes that image only" do
      with_fixture_fleet do |env|
        run = run_fleet_in(env.dir, ["repos", "update-readme", "ruby"])

        run.code.should eq 0
        run.stdout.should eq "#{written(env, "ruby")}\n\nDone! 1 README(s) updated, 0 skipped.\n"
        image_readme_of(env, "ruby").should eq expected_fleet_file("docker-images/ruby/README.md")
        File.exists?(File.join(env.dir, "docker-images", "traefik", "README.md")).should be_false
      end
    end

    it "says a name that is declared but not cloned is skipped" do
      with_fixture_fleet do |env|
        run = run_fleet_in(env.dir, ["repos", "update-readme", "absent"])

        run.code.should eq 0
        run.stdout.should eq "  skip absent (not cloned)\n\nDone! 0 README(s) updated, 1 skipped.\n"
      end
    end

    it "refuses a name the manifest does not declare" do
      with_fixture_fleet do |env|
        run = run_fleet_in(env.dir, ["repos", "update-readme", "nope"])

        run.code.should eq 1
        run.stderr.should eq "donico-manager: Unknown repository: nope\n"
        run.stdout.should be_empty
      end
    end

    it "refuses an option and a surplus argument" do
      with_fixture_fleet do |env|
        run_fleet_in(env.dir, ["repos", "update-readme", "--nope"]).stderr.should eq "donico-manager: unknown option: --nope\n"
        run_fleet_in(env.dir, ["repos", "update-readme", "ruby", "alloy"]).stderr.should eq "donico-manager: unexpected argument: alloy\n"
      end
    end
  end

  # Mid-sweep, an unreadable config must not abandon the images after it.
  describe "an image whose config cannot be used" do
    it "is skipped when it carries no config" do
      with_fixture_fleet do |env|
        File.delete(File.join(env.dir, "docker-images", "ruby", "donico.yml"))
        image_readmes_for(env)

        env.stdout.to_s.should contain "  skip ruby (no donico.yml)\n"
        env.stdout.to_s.should end_with "\nDone! 5 README(s) updated, 2 skipped.\n"
      end
    end

    it "is skipped when empty, and the next image is still written" do
      with_fixture_fleet do |env|
        overwrite_image(env, "debian-base", "donico.yml", "")
        image_readmes_for(env)

        env.stdout.to_s.should contain "  skip debian-base (donico.yml is empty or does not parse)\n"
        image_readme_of(env, "traefik").should eq expected_fleet_file("docker-images/traefik/README.md")
      end
    end

    it "is skipped when it does not parse, and its existing README is untouched" do
      with_fixture_fleet do |env|
        overwrite_image(env, "alloy", "donico.yml", "matrix: [\n")
        overwrite_image(env, "alloy", "README.md", "kept\n")
        image_readmes_for(env)

        env.stdout.to_s.should contain "  skip alloy (donico.yml is empty or does not parse)\n"
        image_readme_of(env, "alloy").should eq "kept\n"
        image_readme_of(env, "traefik").should eq expected_fleet_file("docker-images/traefik/README.md")
      end
    end
  end
end
