require "../spec_helper"

private BASE = <<-YAML
  registry: r.example/base
  image_name: docker-in-docker
  matrix:
    - version: "1.2.3"
      distro: trixie
      tags: ["latest-%<distro>s", "%<version>s-%<distro>s"]
      build_args: ["FOO=bar"]
      test_args: ["Token=AbC=", "alpha=1"]
  YAML

# The images of `yaml`, built from a real project directory.
private def images_from(yaml : String, vars : Hash(String, String) = {"CI_COMMIT_TIMESTAMP" => "2026-07-31T00:00:00Z"}) : Array(Donico::Image)
  with_project(yaml, vars: vars) { |env| return Donico::Image.all(Donico::Config.load(env)) }
  raise "unreachable"
end

private def image_from(yaml : String = BASE, vars : Hash(String, String) = {"CI_COMMIT_TIMESTAMP" => "2026-07-31T00:00:00Z"}) : Donico::Image
  images_from(yaml, vars).first
end

private def named(name : String) : Donico::Image
  image_from("registry: r.example/base\nimage_name: #{name}\n")
end

describe Donico::Image do
  describe ".all" do
    it "builds one image per matrix row, in matrix order" do
      yaml = "registry: r\nimage_name: foo\nmatrix:\n  - {version: \"2\", distro: b}\n  - {version: \"1\", distro: a}\n"
      images_from(yaml).map(&.task_prefix).should eq ["b:2", "a:1"]
    end

    it "does not read the timestamp when an image is built" do
      images = images_from(BASE, {"CI_COMMIT_TIMESTAMP" => "nonsense"})
      images.size.should eq 1
    end

    it "raises the bad timestamp error on first use of a timestamp" do
      image = images_from(BASE, {"CI_COMMIT_TIMESTAMP" => "nonsense"}).first
      message = %(CI_COMMIT_TIMESTAMP is not an ISO 8601 timestamp: "nonsense")
      expect_raises(Donico::ConfigError, message) { image.build_tag }
      expect_raises(Donico::ConfigError, message) { image.prod_tags }
      expect_raises(Donico::ConfigError, message) { image.raw_build_args }
      expect_raises(Donico::ConfigError, message) { image.inspec_inputs }
    end
  end

  describe "accessors" do
    it "exposes name, registry, distro, version and the entry" do
      image = image_from
      image.name.should eq "docker-in-docker"
      image.registry.should eq "r.example/base"
      image.distro.should eq "trixie"
      image.version.should eq "1.2.3"
      image.entry.build_args.should eq ["FOO=bar"]
    end

    it "prefers the per-entry image_name over the top-level one" do
      yaml = "registry: r\nimage_name: foo\nmatrix:\n  - {image_name: bookworm, version: \"1.0.0\"}\n"
      image_from(yaml).name.should eq "bookworm"
    end

    it "falls back to the top-level image_name" do
      yaml = "registry: r\nimage_name: foo\nmatrix:\n  - {version: \"1.0.0\"}\n"
      image_from(yaml).name.should eq "foo"
    end
  end

  describe "#build_tag" do
    it "joins name, version, distro and timestamp" do
      image_from.build_tag.should eq "docker-in-docker/1.2.3/trixie:20260731000000"
    end

    it "uses the date of the clock without CI_COMMIT_TIMESTAMP" do
      image_from(BASE, {} of String => String).build_tag.should eq "docker-in-docker/1.2.3/trixie:20260731"
    end
  end

  describe "#prod_tags" do
    it "expands each pattern under registry/name and sorts the result" do
      image_from(BASE, {} of String => String).prod_tags.should eq [
        "r.example/base/docker-in-docker:1.2.3-trixie",
        "r.example/base/docker-in-docker:latest-trixie",
      ]
    end

    it "expands the timestamp macro" do
      yaml = "registry: r.example/base\nimage_name: docker-in-docker\nmatrix:\n  - version: \"1.2.3\"\n    distro: trixie\n    tags: [\"%<version>s-%<distro>s-%<timestamp>s\"]\n"
      image_from(yaml, {} of String => String).prod_tags.should eq [
        "r.example/base/docker-in-docker:1.2.3-trixie-20260731",
      ]
    end

    it "sorts the expanded tags, not the patterns" do
      yaml = "registry: r\nimage_name: n\nmatrix:\n  - version: \"2\"\n    distro: d\n    tags: [\"z-%<version>s\", \"a-%<distro>s\"]\n"
      image_from(yaml).prod_tags.should eq ["r/n:a-d", "r/n:z-2"]
    end
  end

  describe "#raw_build_args" do
    it "adds the three injected args and sorts as plain strings" do
      image_from(BASE, {} of String => String).raw_build_args.should eq [
        "BUILD_DATE=20260731", "DISTRO_NAME=trixie", "DOCKER_IN_DOCKER_VERSION=1.2.3", "FOO=bar",
      ]
    end

    it "sorts upper case before lower case" do
      yaml = "registry: r\nimage_name: n\nmatrix:\n  - version: \"1\"\n    distro: d\n    build_args: [\"alpha=1\", \"Zed=2\"]\n"
      image_from(yaml).raw_build_args.should eq [
        "BUILD_DATE=20260731000000", "DISTRO_NAME=d", "N_VERSION=1", "Zed=2", "alpha=1",
      ]
    end
  end

  describe "version variable name" do
    it "upcases a simple name" do
      named("foo").raw_build_args.should contain "FOO_VERSION=latest"
    end

    it "turns dashes into underscores" do
      named("docker-in-docker").raw_build_args.should contain "DOCKER_IN_DOCKER_VERSION=latest"
    end

    it "splits camel case on the case boundary" do
      named("MyApp").raw_build_args.should contain "MY_APP_VERSION=latest"
    end

    it "splits consecutive capitals before a capitalised word" do
      named("HTTPServer").raw_build_args.should contain "HTTP_SERVER_VERSION=latest"
    end

    it "splits a digit followed by a capital" do
      named("my_app2Go").raw_build_args.should contain "MY_APP2_GO_VERSION=latest"
    end

    # Not a character an argument name can hold: `team/node.js` used to give
    # `TEAM/NODE.JS_VERSION`, which bake refuses.
    it "turns a slash and a dot into underscores" do
      named("team/node.js").raw_build_args.should contain "TEAM_NODE_JS_VERSION=latest"
    end
  end

  describe "#bake_env" do
    it "holds BUILD_DATE alone, whatever the row declares" do
      image_from(BASE, {} of String => String).bake_env.should eq({"BUILD_DATE" => "20260731"})
      yaml = "registry: r\nimage_name: n\nmatrix:\n  - version: \"1\"\n    distro: d\n    build_args: [\"PATH=/opt/bin\", \"DOCKER_HOST=tcp://x\"]\n"
      image_from(yaml).bake_env.keys.should eq ["BUILD_DATE"]
    end
  end

  describe "empty values" do
    it "keeps an empty build arg value in the args and the inputs" do
      yaml = "registry: r\nimage_name: n\nmatrix:\n  - version: \"1\"\n    distro: d\n    build_args: [\"A=\"]\n"
      image = image_from(yaml)
      image.raw_build_args.should contain "A="
      image.inspec_inputs.should contain "a="
    end
  end

  describe "#inspec_inputs" do
    it "sorts on the original case first, then lower-cases the names only" do
      image_from(BASE, {} of String => String).inspec_inputs.should eq [
        "build_date=20260731", "distro_name=trixie", "docker_in_docker_version=1.2.3",
        "foo=bar", "token=AbC=", "alpha=1",
      ]
    end

    it "lower-cases a whole item that has no separator" do
      yaml = "registry: r\nimage_name: n\nmatrix:\n  - version: \"1\"\n    distro: d\n    test_args: [\"FLAG\"]\n"
      image_from(yaml).inspec_inputs.should contain "flag"
    end
  end

  describe "targets" do
    it "replaces the dots of the version by dashes" do
      image = image_from
      image.build_target.should eq "trixie-1-2-3-build"
      image.push_target.should eq "trixie-1-2-3-push"
      image.task_prefix.should eq "trixie:1.2.3"
    end

    it "keeps every other character of the version" do
      yaml = "registry: r\nimage_name: n\nmatrix:\n  - {version: \"1.26.3-01\", distro: trixie}\n"
      image_from(yaml).build_target.should eq "trixie-1-26-3-01-build"
    end
  end
end
