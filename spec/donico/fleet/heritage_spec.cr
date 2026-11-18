require "../../spec_helper"

private def heritage_of(env : Donico::Env) : Nil
  Donico::Fleet::Heritage.new(fleet_repos_of(env), env).run
end

# A fleet whose registries mirror the gem's spec: one base and two debian ones
# that the tree resolves to virtual parents.
private def heritage_manifest(images : Array(String), output : String = "doc/tree.md", registries : Bool = true) : String
  lines = [
    "registry: harbor.example.org/base",
    "group: git@example.org:factory/images",
    "workspace: docker-images",
    "heritage_output: #{output}",
  ]
  if registries
    lines.concat ["registries:", "  debian_jbox: harbor.example.org/jbox/debian", "  debian_base: harbor.example.org/debian"]
  else
    lines << "registries: {}"
  end
  lines << "images:"
  images.each { |image| lines << "  - #{image}" }
  lines.join('\n') + "\n"
end

# Runs the command on a fleet of `images` whose root Dockerfiles hold the given
# lines, and yields the text it wrote at `output`.
private def with_heritage(images : Array(String), froms : Hash(String, String),
                          output : String = "doc/tree.md", registries : Bool = true, & : String ->) : Nil
  files = froms.transform_keys { |image| "docker-images/#{image}/Dockerfile" }.transform_values { |from| "#{from}\nRUN true\n" }
  with_fleet(heritage_manifest(images, output, registries), files) do |env|
    heritage_of(env)
    yield File.read(File.join(env.dir, output))
  end
end

describe Donico::Fleet::Heritage do
  it "writes the file the gem writes for the fixture fleet, and says where" do
    with_fixture_fleet do |env|
      heritage_of(env)

      path = File.join(env.dir, "doc/heritage/image-heritage.md")
      File.read(path).should eq expected_fleet_file("doc/heritage/image-heritage.md")
      env.stdout.to_s.should eq "Written #{path}\n"
    end
  end

  it "reads an image without a root Dockerfile from the first dockerfiles/**/Dockerfile in sorted order" do
    with_fleet(heritage_manifest(%w[mise debian-jbox]), {
      "docker-images/debian-jbox/Dockerfile"          => "FROM harbor.example.org/debian/trixie:latest\n",
      "docker-images/mise/dockerfiles/b/Dockerfile"   => "FROM docker.io/library/alpine:3\n",
      "docker-images/mise/dockerfiles/a-b/Dockerfile" => "FROM docker.io/library/busybox:1\n",
      "docker-images/mise/dockerfiles/a/Dockerfile"   => "FROM harbor.example.org/jbox/debian/trixie:latest\n",
    }) do |env|
      heritage_of(env)

      tree = File.read(File.join(env.dir, "doc/tree.md"))
      tree.should contain "└── debian-jbox\n    └── mise\n"
      tree.should_not contain "alpine"
      tree.should_not contain "busybox"
    end
  end

  it "prefers the root Dockerfile over those under dockerfiles/" do
    with_fleet(heritage_manifest(%w[mise]), {
      "docker-images/mise/Dockerfile"               => "FROM docker.io/library/alpine:3\n",
      "docker-images/mise/dockerfiles/a/Dockerfile" => "FROM docker.io/library/busybox:1\n",
    }) do |env|
      heritage_of(env)

      File.read(File.join(env.dir, "doc/tree.md")).should contain "| mise | `docker.io/library/alpine` |"
    end
  end

  it "nests an image under the base image it derives from" do
    with_heritage(%w[debian-jbox mise ruby], {
      "debian-jbox" => "FROM harbor.example.org/debian/trixie:latest",
      "mise"        => "FROM harbor.example.org/jbox/debian/trixie:latest",
      "ruby"        => "FROM harbor.example.org/base/mise:latest-trixie",
    }) do |tree|
      tree.should contain "└── ruby"
    end
  end

  it "lists an image with an external base in its own table" do
    with_heritage(%w[gotenberg], {"gotenberg" => "FROM gotenberg/gotenberg:8.34.0"}) do |tree|
      tree.should contain "## Images avec base externe"
      tree.should contain "| gotenberg | `gotenberg/gotenberg` |"
    end
  end

  it "keeps every segment of an external reference" do
    with_heritage(%w[openldap], {"openldap" => "FROM docker.io/bitnami/minideb:${DISTRO_NAME}"}) do |tree|
      tree.should contain "| openldap | `docker.io/bitnami/minideb` |"
    end
  end

  it "omits the tree section when no image derives from another" do
    with_heritage(%w[ruby-ci], {"ruby-ci" => "FROM harbor.other.org/jbox/base/ruby:1"}) do |tree|
      tree.should_not contain "## Arbre"
      tree.should_not contain "```"
      tree.should contain "| ruby-ci | `harbor.other.org/jbox/base/ruby` |"
    end
  end

  it "does not present an image that is not cloned as a root of the tree" do
    with_heritage(%w[debian-jbox absent], {"debian-jbox" => "FROM harbor.example.org/debian/trixie:latest"}) do |tree|
      block = tree[/## Arbre.*?```\n(.*?)```/m, 1]
      block.should_not be_nil
      block.to_s.should_not contain "absent"
      block.to_s.should contain "debian-jbox"
    end
  end

  it "lists it apart, as a base it could not determine" do
    with_heritage(%w[absent], {} of String => String) do |tree|
      tree.should contain "## Images à base indéterminée"
      tree.should contain "| absent |"
    end
  end

  it "lists an image whose Dockerfile has no FROM line as undetermined, not as a root" do
    with_heritage(%w[bare], {"bare" => "# nothing"}) do |tree|
      tree.should contain "| bare |"
      tree.should_not contain "## Arbre"
    end
  end

  it "lists a FROM cycle in its own section and writes the rest" do
    with_heritage(%w[alpha bravo], {
      "alpha" => "FROM harbor.example.org/base/bravo:latest",
      "bravo" => "FROM harbor.example.org/base/alpha:latest",
    }) do |tree|
      tree.should contain "## Images en cycle de FROM"
      tree.should contain "| alpha | `bravo` |"
      tree.should contain "| bravo | `alpha` |"
      tree.should_not contain "## Arbre"
    end
  end

  it "resolves a parent whose tag is an unexpanded variable" do
    with_heritage(%w[debian-jbox mise], {
      "debian-jbox" => "FROM harbor.example.org/debian/trixie:latest",
      "mise"        => "FROM harbor.example.org/jbox/debian/${DISTRO_NAME}:latest",
    }) do |tree|
      tree.should contain "└── debian-jbox\n    └── mise\n"
    end
  end

  it "reads the first stage of a multi-stage build" do
    with_heritage(%w[mise donico], {
      "mise"   => "FROM harbor.example.org/debian/trixie:latest",
      "donico" => "FROM harbor.example.org/base/mise:latest AS builder",
    }) do |tree|
      tree.should contain "└── donico"
    end
  end

  it "points the link back to CLAUDE.md as many levels up as the output is deep" do
    with_heritage(%w[mise], {"mise" => "FROM x/y:1"}, output: "doc/claude/app/heritage.md") do |tree|
      tree.should contain "(../../../CLAUDE.md)"
    end
  end

  it "has no prefix when the file sits at the root" do
    with_heritage(%w[mise], {"mise" => "FROM x/y:1"}, output: "HERITAGE.md") do |tree|
      tree.should contain "(CLAUDE.md)"
    end
  end

  it "matches nothing for a registry the manifest does not declare" do
    with_heritage(%w[ruby-ci], {"ruby-ci" => "FROM harbor.other.org/jbox/base/ruby:1"}, registries: false) do |tree|
      tree.should contain "## Images avec base externe"
      tree.should contain "ruby-ci"
      tree.should_not contain "## Arbre"
    end
  end

  describe "on the command line" do
    it "runs as `donico-manager heritage`, status 0" do
      with_fixture_fleet do |env|
        run = run_fleet_in(env.dir, ["heritage"])

        run.code.should eq 0
        run.stdout.should eq "Written #{File.join(env.dir, "doc/heritage/image-heritage.md")}\n"
        run.stderr.should be_empty
        File.read(File.join(env.dir, "doc/heritage/image-heritage.md")).should eq expected_fleet_file("doc/heritage/image-heritage.md")
      end
    end

    it "refuses an option and a surplus argument, and writes nothing" do
      with_fixture_fleet do |env|
        run_fleet_in(env.dir, ["heritage", "--nope"]).stderr.should eq "donico-manager: unknown option: --nope\n"
        run_fleet_in(env.dir, ["heritage", "ruby"]).stderr.should eq "donico-manager: unexpected argument: ruby\n"
        Dir.exists?(File.join(env.dir, "doc")).should be_false
      end
    end

    it "reports a directory without a manifest on one line, status 1" do
      with_tmp_dir do |dir|
        run = run_fleet_in(dir, ["heritage"])

        run.code.should eq 1
        run.stderr.should eq "donico-manager: donico-manager.yml not found. donico-manager runs from the root of a fleet's configuration repository.\n"
      end
    end
  end
end
