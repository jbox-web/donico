require "../../spec_helper"

# What `update-readme` narrates on the fixture fleet, as the gem prints it
# (see spec/fixtures/fleet/README.md): one skip line per image left out, then
# one badge line per row, the planned images after the cloned ones of their
# section.
FIXTURE_README_NARRATION = [
  "Updating README.md",
  "  skip absent (not cloned)",
  "  skip nocategory (donico.yml declares no category)",
  "Adding badge for alloy",
  "Adding badge for ruby",
  "Adding badge for traefik",
  "Adding badge for caddy",
  "Adding badge for debian-base",
  "Adding badge for firefox",
  "Adding badge for thunderbird",
  "Done!",
].join('\n') + "\n"

private def readme_of(env : Donico::Env) : String
  File.read(File.join(env.dir, "README.md"))
end

private def readme_for(env : Donico::Env) : Nil
  Donico::Fleet::Readme.new(fleet_repos_of(env), env).run
end

private def stdout_of(env : Donico::Env) : String
  env.stdout.to_s
end

private def overwrite(env : Donico::Env, path : String, text : String) : Nil
  File.write(File.join(env.dir, path), text)
end

describe Donico::Fleet::Readme do
  it "writes the README the gem writes, and narrates it" do
    with_fixture_fleet do |env|
      readme_for(env)

      readme_of(env).should eq expected_fleet_file("README.md")
      stdout_of(env).should eq FIXTURE_README_NARRATION
    end
  end

  # The template is the fleet's own text; the tables come after it.
  it "starts from the template" do
    with_fixture_fleet do |env|
      overwrite(env, "templates/README.md", "# Mine\n\nIntro.\n\n")
      readme_for(env)

      readme_of(env).should start_with "# Mine\n\nIntro.\n\n## Total images : 5\n\n## Web (3)\n"
    end
  end

  it "counts an image whose category is not declared, and shows it in no table" do
    with_fixture_fleet do |env|
      readme_for(env)

      readme_of(env).should contain "## Total images : 5"
      readme_of(env).should_not contain "debuerreotype"
      readme_of(env).should_not contain "Distro"
    end
  end

  # Psych reads the unquoted 3.10 as the float 3.1, and the gem prints that.
  it "prints an unquoted 3.10 as the YAML parser reads it" do
    with_fixture_fleet do |env|
      readme_for(env)

      readme_of(env).should contain "<code>harbor.example.org/base/ruby:3.1</code>"
      readme_of(env).should_not contain "ruby:3.10"
    end
  end

  it "reads a danico.yml" do
    with_fixture_fleet do |env|
      overwrite(env, "donico-manager.yml", File.read(File.join(env.dir, "donico-manager.yml")).sub("  - desktop\n", "  - desktop\n  - distro\n"))
      readme_for(env)

      readme_of(env).should contain "## Distro (1)\n\n| Image | CI Status | Upstream | Registry link |\n|-------|-----------|----------|---------------|\n| [debuerreotype](https://gitlab.example.org/factory/images/debuerreotype)"
    end
  end

  it "replaces the version and distro of a tag pattern and leaves anything else as written" do
    with_fixture_fleet do |env|
      overwrite(env, "docker-images/ruby/donico.yml", <<-YAML)
        registry: harbor.example.org/base
        category: web
        matrix:
          - version: "1.0"
            distro: trixie
            tags:
              - "%<version>s-%<distro>s-%<timestamp>s-%%-%d"
        YAML
      readme_for(env)

      readme_of(env).should contain "<code>harbor.example.org/base/ruby:1.0-trixie-%<timestamp>s-%%-%d</code>"
    end
  end

  it "defaults the tags to the version, and the version to latest" do
    with_fixture_fleet do |env|
      overwrite(env, "docker-images/ruby/donico.yml", <<-YAML)
        registry: harbor.example.org/base
        category: web
        matrix:
          - version: "1.0"
          - distro: trixie
        YAML
      readme_for(env)

      readme_of(env).should contain "<ul><li><code>harbor.example.org/base/ruby:1.0</code></li><li><code>harbor.example.org/base/ruby:latest</code></li></ul>"
    end
  end

  it "leaves out the upstream badge of an image without github_repo" do
    with_fixture_fleet do |env|
      readme_for(env)

      readme_of(env).lines.find!(&.starts_with?("| [ruby]")).should contain "| <ul></ul> |"
    end
  end

  describe "the CI badge of a row" do
    it "is the pipeline badge of GitLab by default" do
      with_fixture_fleet do |env|
        readme_for(env)

        readme_of(env).lines.find!(&.starts_with?("| [ruby]")).should contain(
          "| <ul>[![pipeline status](https://gitlab.example.org/factory/images/ruby/badges/master/pipeline.svg)]" \
          "(https://gitlab.example.org/factory/images/ruby/-/pipelines)</ul> |")
      end
    end

    it "is the workflow badge of GitHub Actions when the fleet says forge: github" do
      with_fixture_fleet do |env|
        manifest = File.read(File.join(env.dir, "donico-manager.yml"))
        manifest = manifest.sub("browse_url: https://gitlab.example.org/factory/images", "browse_url: https://github.com/factory")
        overwrite(env, "donico-manager.yml", "#{manifest}forge: github\n")
        readme_for(env)

        readme_of(env).lines.find!(&.starts_with?("| [ruby]")).should start_with(
          "| [ruby](https://github.com/factory/ruby) " \
          "| <ul>[![workflow status](https://github.com/factory/ruby/actions/workflows/images.yml/badge.svg)]" \
          "(https://github.com/factory/ruby/actions/workflows/images.yml)</ul> |")
      end
    end

    it "names the workflow of ci_workflow" do
      with_fixture_fleet do |env|
        manifest = File.read(File.join(env.dir, "donico-manager.yml"))
        overwrite(env, "donico-manager.yml", "#{manifest}forge: github\nci_workflow: build.yml\n")
        readme_for(env)

        readme_of(env).lines.find!(&.starts_with?("| [ruby]")).should contain "/ruby/actions/workflows/build.yml/badge.svg)]"
      end
    end
  end

  describe "a template that is missing" do
    it "is the error naming it, and the existing README is untouched" do
      with_fixture_fleet do |env|
        File.delete(File.join(env.dir, "templates", "README.md"))
        overwrite(env, "README.md", "kept\n")

        error = expect_raises(Donico::Error) { readme_for(env) }

        error.message.should eq "templates/README.md not found. The root README is generated from it."
        readme_of(env).should eq "kept\n"
        stdout_of(env).should eq "Updating README.md\n"
      end
    end
  end

  # A workspace is routinely partial and a donico.yml sometimes half written:
  # neither may cost the README, which is replaced in place.
  describe "an image whose donico.yml cannot be used" do
    it "is skipped with its reason when it is not YAML, and the README is complete for the others" do
      with_fixture_fleet do |env|
        overwrite(env, "docker-images/ruby/donico.yml", "matrix: [\n")
        overwrite(env, "README.md", "old\n")
        readme_for(env)

        stdout_of(env).should contain "  skip ruby (donico.yml does not parse)\n"
        readme_of(env).should start_with "# Example fleet\n"
        readme_of(env).should contain "## Total images : 4\n"
        readme_of(env).should contain "## Web (2)\n"
        readme_of(env).should contain "[alloy]("
        readme_of(env).should contain "[traefik]("
        readme_of(env).should contain "[debian-base]("
        readme_of(env).should contain "| *thunderbird* | *todo* | *todo* | *todo* |\n"
        readme_of(env).should_not contain "[ruby]("
      end
    end

    it "is skipped when the file is empty" do
      with_fixture_fleet do |env|
        overwrite(env, "docker-images/ruby/donico.yml", "")
        readme_for(env)

        stdout_of(env).should contain "  skip ruby (donico.yml does not parse)\n"
      end
    end

    it "is skipped when it declares no matrix" do
      with_fixture_fleet do |env|
        overwrite(env, "docker-images/ruby/donico.yml", "category: web\n")
        readme_for(env)

        stdout_of(env).should contain "  skip ruby (donico.yml declares no matrix)\n"
      end
    end

    it "is skipped when its matrix is not a list" do
      with_fixture_fleet do |env|
        overwrite(env, "docker-images/ruby/donico.yml", "category: web\nmatrix:\n  version: \"1\"\n")
        readme_for(env)

        stdout_of(env).should contain "  skip ruby (donico.yml declares no matrix)\n"
      end
    end

    it "is skipped when its category is empty" do
      with_fixture_fleet do |env|
        overwrite(env, "docker-images/ruby/donico.yml", "category: \"\"\nmatrix:\n  - version: \"1\"\n")
        readme_for(env)

        stdout_of(env).should contain "  skip ruby (donico.yml declares no category)\n"
      end
    end

    it "is skipped, not a crash, when the file holds a list instead of a mapping" do
      with_fixture_fleet do |env|
        overwrite(env, "docker-images/ruby/donico.yml", "- one\n- two\n")
        readme_for(env)

        stdout_of(env).should contain "  skip ruby (donico.yml declares no matrix)\n"
      end
    end
  end

  describe "the planned images" do
    it "works without a todo.yml" do
      with_fixture_fleet do |env|
        File.delete(File.join(env.dir, "todo.yml"))
        readme_for(env)

        readme_of(env).should_not contain "*todo*"
        stdout_of(env).should end_with "Done!\n"
      end
    end

    it "works with an empty todo.yml and with one that declares no images" do
      ["", "note: nothing planned\n", "images: []\n"].each do |body|
        with_fixture_fleet do |env|
          overwrite(env, "todo.yml", body)
          readme_for(env)

          readme_of(env).should_not contain "*todo*"
        end
      end
    end

    it "lists what todo.yml declares for a section, after the images of that section" do
      with_fixture_fleet do |env|
        overwrite(env, "todo.yml", "images:\n  tools:\n    - hadolint\n")
        readme_for(env)

        readme_of(env).should contain "| *hadolint* | *todo* | *todo* | *todo* |\n"
        readme_of(env).index!("[debian-base]").should be < readme_of(env).index!("*hadolint*")
      end
    end

    it "refuses a todo.yml that is not YAML before touching the README" do
      with_fixture_fleet do |env|
        overwrite(env, "todo.yml", "images: [\n")
        overwrite(env, "README.md", "kept\n")

        error = expect_raises(Donico::Error) { readme_for(env) }

        error.message.should eq "todo.yml: invalid YAML."
        readme_of(env).should eq "kept\n"
      end
    end
  end

  describe "the command" do
    it "is update-readme, with no argument" do
      with_fixture_fleet do |env|
        run = run_fleet_in(env.dir, ["update-readme"])

        run.code.should eq 0
        run.stdout.should eq FIXTURE_README_NARRATION
        run.stderr.should be_empty
        readme_of(env).should eq expected_fleet_file("README.md")
      end
    end

    it "refuses an option and a surplus argument, and writes nothing" do
      with_fixture_fleet do |env|
        run_fleet_in(env.dir, ["update-readme", "--nope"]).stderr.should eq "donico-manager: unknown option: --nope\n"
        run_fleet_in(env.dir, ["update-readme", "ruby"]).stderr.should eq "donico-manager: unexpected argument: ruby\n"
        File.exists?(File.join(env.dir, "README.md")).should be_false
      end
    end

    it "reports the missing template on one line, status 1" do
      with_fixture_fleet do |env|
        File.delete(File.join(env.dir, "templates", "README.md"))
        run = run_fleet_in(env.dir, ["update-readme"])

        run.code.should eq 1
        run.stderr.should eq "donico-manager: templates/README.md not found. The root README is generated from it.\n"
      end
    end
  end
end
