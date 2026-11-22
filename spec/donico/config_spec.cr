require "../spec_helper"

private MINIMAL = "registry: registry.example.net\nimage_name: foo\n"

private def fixture(name : String) : String
  File.read(File.join(__DIR__, "..", "fixtures", name))
end

# Loads `yaml` through a real project directory, the way the CLI does.
private def config_from(yaml : String, vars : Hash(String, String) = {} of String => String,
                        now : Time = Time.local(2026, 7, 31, 23, 59, 59, location: Time::Location::UTC)) : Donico::Config
  with_project(yaml, vars: vars, now: now) { |env| return Donico::Config.load(env) }
  raise "unreachable"
end

private def config_error(yaml : String) : String?
  expect_raises(Donico::ConfigError) { config_from(yaml) }.message
end

private def tags_error(tag : String) : String?
  config_error(MINIMAL + "matrix:\n  - version: \"1.0.0\"\n    tags: [#{tag.inspect}]\n")
end

describe Donico::Config do
  describe ".load" do
    it "reads the fixture with every key set" do
      config = config_from(fixture("config/custom.yml"))
      config.registry.should eq "registry.example.net/images/base"
      config.image_name.should eq "foo"
      config.matrix.size.should eq 1
      entry = config.matrix.first
      entry.version.should eq "1.0.0"
      entry.distro.should eq "buster"
      entry.archs.should eq ["linux/amd64"]
      entry.dockerfile.should eq "foo/Dockerfile"
      entry.build_args.should eq ["NODEJS_VERSION=14.17.3"]
      entry.test_args.should eq ["RUBYGEM_VERSION=3.2.24"]
      entry.secret_envs.should eq [] of Hash(String, String)
      entry.secret_files.should eq [] of Hash(String, String)
      entry.tags.should eq [
        "latest",
        "%<version>s",
        "%<version>s-%<distro>s",
        "%<timestamp>s-%<distro>s",
        "%<version>s-%<timestamp>s-%<distro>s",
      ]
    end

    # What this proves is that none of them is refused; what each one loads
    # as is checked by the specs that render it.
    it "loads the six bake fixtures, one row per entry of their matrix" do
      rows = {"custom" => 1, "debian" => 8, "escaping" => 1, "minimal" => 1, "multiple_dockerfiles" => 2, "quoted_versions" => 3}
      rows.each do |name, count|
        config_from(fixture("bake/#{name}.yml")).matrix.size.should eq count
      end
    end

    # donico.example.yml is the file a user copies to start a repository: an
    # example that does not load, or that no longer shows a key, is worse than
    # none.
    it "loads donico.example.yml, which shows every key" do
      config = config_from(File.read(File.join(__DIR__, "..", "..", "donico.example.yml")))

      config.registry.should eq "registry.example.com/base"
      config.image_name.should eq "myapp"
      config.image_builder.should eq "bake"
      config.tools_registry.should eq "registry.example.com/tools"
      config.matrix.map { |row| {row.distro, row.version} }.should eq [{"bookworm", "1.0"}, {"trixie", "1.0"}]

      first, second = config.matrix
      first.archs.should eq ["linux/amd64", "linux/arm64"]
      first.dockerfile.should eq "Dockerfile"
      first.build_args.should eq ["APP_USER=app"]
      first.test_args.should eq ["expected_user=app"]
      first.tags.should eq ["%<version>s-%<distro>s", "%<version>s-%<distro>s-%<timestamp>s"]
      first.secret_envs.should eq [{"id" => "GITHUB_TOKEN"}]
      first.secret_files.should eq [{"id" => "netrc", "src" => ".netrc"}]
      first.test_variants.should eq [["run_mode=default"], ["run_mode=dind"]]
      first.login_env.should eq ["SSH_PRIVATE_KEY"]
      # The second row overrides the tags it merged and adds nothing else.
      second.tags.should eq ["%<version>s-%<distro>s", "latest"]
      second.archs.should eq ["linux/amd64", "linux/arm64"]
      second.secret_envs.should be_empty
    end

    it "reports a missing file with its directory" do
      with_project("") do |env|
        File.delete(File.join(env.dir, "donico.yml"))
        error = expect_raises(Donico::ConfigError) { Donico::Config.load(env) }
        error.message.should eq "donico.yml not found in #{env.dir}"
      end
    end

    it "reports an unreadable file as a ConfigError" do
      with_project(MINIMAL) do |env|
        path = File.join(env.dir, "donico.yml")
        File.chmod(path, 0o000)
        begin
          # Root reads anything: the case cannot be produced there.
          pending!("file stays readable (running as root)") if File::Info.readable?(path)
          error = expect_raises(Donico::ConfigError) { Donico::Config.load(env) }
          error.message.should eq "donico.yml: cannot be read"
        ensure
          File.chmod(path, 0o644)
        end
      end
    end

    it "rejects an empty file" do
      config_error("").should eq "donico.yml: expected a mapping at the top level"
    end

    it "rejects a list at the top level" do
      config_error("- a\n- b\n").should eq "donico.yml: expected a mapping at the top level"
    end

    it "reports invalid YAML as a ConfigError, not a parser exception" do
      message = config_error("a: b: c\n").to_s
      message.should start_with "donico.yml: invalid YAML: "
      message.should_not contain '\n'
    end
  end

  describe "defaults and ignored keys" do
    it "defaults image_builder to bake" do
      config_from(MINIMAL).image_builder.should eq "bake"
    end

    it "accepts image_builder: bake" do
      config_from(MINIMAL + "image_builder: bake\n").image_builder.should eq "bake"
    end

    it "gives one default row when matrix is absent" do
      config = config_from(MINIMAL)
      config.matrix.size.should eq 1
      entry = config.matrix.first
      entry.version.should eq "latest"
      entry.distro.should eq "buster"
      entry.archs.should eq ["linux/amd64"]
      entry.build_args.should eq [] of String
      entry.test_args.should eq [] of String
      entry.tags.should eq ["%<version>s-%<distro>s"]
    end

    it "keeps an ERB-looking value as literal text" do
      config = config_from(MINIMAL + "matrix:\n  - build_args: [\"X=<%= 1 + 1 %>\"]\n")
      config.matrix.first.build_args.should eq ["X=<%= 1 + 1 %>"]
    end

    it "ignores category, description and github_repo" do
      config_from(MINIMAL + "category: a\ndescription: b\ngithub_repo: c\n").registry.should eq "registry.example.net"
    end

    # The gem read this key; the binary ignores it like any unknown key.
    it "ignores commit_linter" do
      config_from(MINIMAL + "commit_linter: x\n").registry.should eq "registry.example.net"
    end

    it "leaves tools_registry unset when the key is absent" do
      config_from(MINIMAL).tools_registry.should be_nil
    end

    it "reads tools_registry, docker_linter and inspec_image" do
      config = config_from(MINIMAL + "tools_registry: tools.example.net\ndocker_linter: lint:1\ninspec_image: insp:2\n")
      config.tools_registry.should eq "tools.example.net"
      config.docker_linter.should eq "lint:1"
      config.inspec_image.should eq "insp:2"
    end

    it "leaves docker_linter and inspec_image unset by default" do
      config = config_from(MINIMAL)
      config.docker_linter.should be_nil
      config.inspec_image.should be_nil
    end
  end

  describe "required keys" do
    it "rejects a missing registry" do
      config_error("image_name: foo\n").should eq "donico.yml: missing required key: registry"
    end

    it "rejects image_builder: docker with a message pointing at bake" do
      config_error(MINIMAL + "image_builder: docker\n").should eq(
        %(donico.yml: image_builder "docker" is not supported by donico 3, use image_builder: bake))
    end

    it "rejects an unknown image_builder" do
      config_error(MINIMAL + "image_builder: kaniko\n").should eq(
        %(donico.yml: unknown image_builder "kaniko" (supported: bake, debuerreotype)))
    end

    # Without a name, tags used to render with an empty segment.
    it "rejects a config where no name is set anywhere" do
      config_error("registry: r\n").should eq(
        "donico.yml: missing image_name (set it at the top level or on every matrix entry)")
    end

    it "rejects a top-level name absent while one row lacks its own" do
      config_error("registry: r\nmatrix:\n  - image_name: a\n    version: \"1\"\n  - version: \"2\"\n").should eq(
        "donico.yml: missing image_name (set it at the top level or on every matrix entry)")
    end

    it "accepts names set on every row only" do
      config_from("registry: r\nmatrix:\n  - image_name: a\n  - image_name: b\n    version: \"2\"\n").matrix.size.should eq 2
    end
  end

  describe "keys written with no value" do
    it "treats a top-level key set to null as absent" do
      config = config_from("registry: r\nimage_name: foo\ntools_registry:\ndocker_linter: ~\n")
      config.tools_registry.should be_nil
      config.docker_linter.should be_nil
    end

    it "treats a null matrix as absent: one row with every default" do
      matrix = config_from("registry: r\nimage_name: foo\nmatrix:\n").matrix
      matrix.size.should eq 1
      matrix.first.distro.should eq "buster"
    end
  end

  describe "wrong types" do
    it "rejects a number for distro, naming the path" do
      config_error(MINIMAL + "matrix:\n  - distro: 12\n").should eq "donico.yml: matrix[0].distro must be a string"
    end

    it "rejects a scalar for archs" do
      config_error(MINIMAL + "matrix:\n  - archs: linux/amd64\n").should eq(
        "donico.yml: matrix[0].archs must be a list of strings")
    end

    it "rejects an empty mapping for matrix" do
      config_error(MINIMAL + "matrix: {}\n").should eq "donico.yml: matrix must be a list of mappings"
    end

    it "rejects a scalar row in matrix" do
      config_error(MINIMAL + "matrix:\n  - buster\n").should eq "donico.yml: matrix must be a list of mappings"
    end

    it "rejects a non-string registry" do
      config_error("registry: 12\nimage_name: foo\n").should eq "donico.yml: registry must be a string"
    end

    it "rejects a non-string image_name" do
      config_error("registry: r\nimage_name: [a]\n").should eq "donico.yml: image_name must be a string"
    end

    it "rejects a non-string tools_registry" do
      config_error(MINIMAL + "tools_registry: 1\n").should eq "donico.yml: tools_registry must be a string"
    end

    it "rejects a non-string docker_linter" do
      config_error(MINIMAL + "docker_linter: [a]\n").should eq "donico.yml: docker_linter must be a string"
    end

    it "rejects a non-string inspec_image" do
      config_error(MINIMAL + "inspec_image: 3\n").should eq "donico.yml: inspec_image must be a string"
    end

    it "rejects a non-string image_builder" do
      config_error(MINIMAL + "image_builder: 1\n").should eq "donico.yml: image_builder must be a string"
    end

    it "reports the right row index" do
      config_error(MINIMAL + "matrix:\n  - version: \"1\"\n  - version: \"2\"\n    build_args: [1]\n").should eq(
        "donico.yml: matrix[1].build_args must be a list of strings")
    end

    it "reports the unquoted version of a row" do
      config_error(MINIMAL + "matrix:\n  - version: 3.10\n").should eq(
        %(donico.yml: matrix[0].version must be a quoted string (YAML read it as 3.1; quote it as written in the file)))
    end
  end

  describe "tags" do
    it "accepts the three macros of the bake backend" do
      config_from(MINIMAL + %(matrix:\n  - tags: ["%<version>s-%<distro>s-%<timestamp>s"]\n)).matrix.first.tags.should eq(
        ["%<version>s-%<distro>s-%<timestamp>s"])
    end

    it "accepts a tag without any macro" do
      config_from(MINIMAL + "matrix:\n  - tags: [latest]\n").matrix.first.tags.should eq ["latest"]
    end

    it "rejects an unknown macro" do
      tags_error("%<foo>s").should eq(
        %(donico.yml: invalid tag "%<foo>s" (allowed macros: %<distro>s, %<timestamp>s, %<version>s; a literal % is not supported)))
    end

    it "rejects a literal percent sign" do
      tags_error("100%-slim").should eq(
        %(donico.yml: invalid tag "100%-slim" (allowed macros: %<distro>s, %<timestamp>s, %<version>s; a literal % is not supported)))
    end

    # bake resolves the platform list itself: no single arch exists at tag time.
    it "rejects the arch macro" do
      tags_error("%<version>s-%<arch>s").should eq(
        %(donico.yml: invalid tag "%<version>s-%<arch>s" (allowed macros: %<distro>s, %<timestamp>s, %<version>s; a literal % is not supported)))
    end

    it "rejects a macro missing its closing letter" do
      tags_error("%<version>").should eq(
        %(donico.yml: invalid tag "%<version>" (allowed macros: %<distro>s, %<timestamp>s, %<version>s; a literal % is not supported)))
    end
  end

  describe "matrix" do
    it "rejects two rows with the same distro and version" do
      yaml = MINIMAL + "matrix:\n  - distro: trixie\n    version: \"1.2.3\"\n  - distro: bookworm\n    version: \"1.2.3\"\n  - distro: trixie\n    version: \"1.2.3\"\n"
      config_error(yaml).should eq "donico.yml: matrix[2] duplicates matrix[0] (trixie:1.2.3)"
    end

    it "accepts the same version on two distros" do
      config_from(MINIMAL + "matrix:\n  - distro: a\n    version: \"1\"\n  - distro: b\n    version: \"1\"\n").matrix.size.should eq 2
    end

    # A row written with the default distro and version duplicates an absent key.
    it "counts defaults when comparing rows" do
      config_error(MINIMAL + "matrix:\n  - {}\n  - distro: buster\n    version: latest\n").should eq(
        "donico.yml: matrix[1] duplicates matrix[0] (buster:latest)")
    end

    it "loads the anchored fixture like its expanded form" do
      anchored = config_from(fixture("config/aliases.yml")).matrix
      expanded = config_from(<<-YAML).matrix
        registry: registry.example.net/images/base
        image_name: foo
        image_builder: bake
        matrix:
          - distro: buster
            archs: ["linux/amd64"]
            version: "1.0.0"
          - distro: buster
            archs: ["linux/amd64"]
            version: "2.0.0"
        YAML
      anchored.map(&.version).should eq ["1.0.0", "2.0.0"]
      anchored.map(&.distro).should eq ["buster", "buster"]
      anchored.map(&.archs).should eq expanded.map(&.archs)
      anchored.map(&.dockerfile).should eq expanded.map(&.dockerfile)
      anchored.map(&.tags).should eq expanded.map(&.tags)
    end

    it "lets a key of the row override the merged default" do
      yaml = MINIMAL + <<-YAML
        x-defaults: &defaults
          distro: trixie
          dockerfile: Dockerfile.base
        matrix:
          - <<: *defaults
            dockerfile: Dockerfile.slim
        YAML
      entry = config_from(yaml).matrix.first
      entry.distro.should eq "trixie"
      entry.dockerfile.should eq "Dockerfile.slim"
    end

    # The gem loads donico.yml with Psych, whose rule for a list of merged
    # mappings is the YAML one: the first mapping that defines a key wins.
    # Measured on the gem: `<<: [*trixie, {distro: sid}]` gives trixie.
    it "gives a list of merged mappings to the first one that defines a key" do
      yaml = MINIMAL + <<-YAML
        .trixie: &trixie
          distro: trixie
          archs: ["linux/arm64"]
        matrix:
          - <<: [*trixie, {distro: sid}]
            version: "1.0.0"
          - <<: [{distro: sid}, *trixie]
            version: "2.0.0"
        YAML
      matrix = config_from(yaml).matrix

      matrix[0].distro.should eq "trixie"
      matrix[0].archs.should eq ["linux/arm64"]
      matrix[1].distro.should eq "sid"
      matrix[1].archs.should eq ["linux/arm64"]
    end

    # Psych applies a merge where it stands: it overrides the keys written
    # before it and is overridden by the keys written after it.
    it "lets a merge override the keys written before it, like the gem" do
      yaml = MINIMAL + <<-YAML
        .trixie: &trixie
          distro: trixie
        matrix:
          - distro: bookworm
            <<: *trixie
            version: "1.0.0"
        YAML

      config_from(yaml).matrix[0].distro.should eq "trixie"
    end
  end

  # What donico.yml may hold is bounded by what the generated files and docker
  # accept: every value refused here used to pass `generate-files` and fail
  # later, at `docker buildx bake`, or build something else than what was
  # written.
  describe "names bake and docker accept" do
    it "refuses a distro that cannot be part of a bake target" do
      message = config_error(MINIMAL + "matrix:\n  - distro: \"a:b\"\n")
      message.should eq %(donico.yml: matrix[0].distro "a:b" is invalid (allowed: letters, digits, _ and -))
    end

    it "refuses an empty distro" do
      message = config_error(MINIMAL + "matrix:\n  - distro: \"\"\n")
      message.should eq %(donico.yml: matrix[0].distro "" is invalid (allowed: letters, digits, _ and -))
    end

    it "refuses a version with a colon or a plus sign" do
      config_error(MINIMAL + "matrix:\n  - version: \"1:2\"\n")
        .should eq %(donico.yml: matrix[0].version "1:2" is invalid (allowed: letters, digits, ., _ and -))
      config_error(MINIMAL + "matrix:\n  - version: \"1.0+b1\"\n")
        .should eq %(donico.yml: matrix[0].version "1.0+b1" is invalid (allowed: letters, digits, ., _ and -))
    end

    it "refuses an empty version" do
      config_error(MINIMAL + "matrix:\n  - version: \"\"\n")
        .should eq %(donico.yml: matrix[0].version "" is invalid (allowed: letters, digits, ., _ and -))
    end

    it "refuses an image name with a space, at the top level and on a row" do
      config_error("registry: r\nimage_name: \"my app\"\n")
        .should eq %(donico.yml: image_name "my app" is invalid (allowed: letters, digits, ., _, - and /))
      config_error(MINIMAL + "matrix:\n  - image_name: \"a:b\"\n")
        .should eq %(donico.yml: matrix[0].image_name "a:b" is invalid (allowed: letters, digits, ., _, - and /))
    end

    it "accepts an image name with a slash and a dot" do
      config_from("registry: r\nimage_name: team/node.js\n").image_name.should eq "team/node.js"
    end

    it "counts an empty registry as missing" do
      config_error("registry: \"\"\nimage_name: foo\n").should eq "donico.yml: missing required key: registry"
    end

    it "counts an empty image_name as missing" do
      config_error("registry: r\nimage_name: \"\"\n")
        .should eq "donico.yml: missing image_name (set it at the top level or on every matrix entry)"
      config_error("registry: r\nmatrix:\n  - image_name: \"\"\n")
        .should eq "donico.yml: missing image_name (set it at the top level or on every matrix entry)"
    end

    it "refuses an empty dockerfile" do
      config_error(MINIMAL + "matrix:\n  - dockerfile: \"\"\n")
        .should eq "donico.yml: matrix[0].dockerfile must not be empty"
    end

    it "refuses an empty tag and a tag docker would refuse" do
      tags_error("").should eq %(donico.yml: invalid tag "" (a tag holds letters, digits, ., _ and -, and the macros %<distro>s, %<timestamp>s, %<version>s))
      tags_error("a b").should eq %(donico.yml: invalid tag "a b" (a tag holds letters, digits, ., _ and -, and the macros %<distro>s, %<timestamp>s, %<version>s))
    end

    it "refuses a build arg whose name is not an identifier" do
      config_error(MINIMAL + "matrix:\n  - build_args: [\"my-arg=1\"]\n")
        .should eq %(donico.yml: matrix[0].build_args[0] has an invalid name "my-arg" (letters, digits and underscores, not starting with a digit))
    end

    it "refuses a build arg declared twice" do
      config_error(MINIMAL + "matrix:\n  - build_args: [\"A=1\", \"B=2\", \"A=3\"]\n")
        .should eq "donico.yml: matrix[0].build_args[2] sets A a second time"
    end

    # DISTRO_NAME, BUILD_DATE and <NAME>_VERSION are written by donico itself.
    # A declared arg of the same name used to be written next to the injected
    # one, and bake kept whichever came last in alphabetical order of the
    # values.
    it "refuses a build arg named like one donico injects" do
      {"DISTRO_NAME=alpine", "BUILD_DATE=x", "FOO_VERSION=0.9"}.each do |arg|
        name = arg.split('=').first
        config_error(MINIMAL + "matrix:\n  - build_args: [\"#{arg}\"]\n")
          .should eq "donico.yml: matrix[0].build_args[0] sets #{name}, which donico sets itself (reserved: BUILD_DATE, DISTRO_NAME, FOO_VERSION)"
      end
    end

    it "computes the reserved version name from the name of the row" do
      yaml = "registry: r\nimage_name: foo\nmatrix:\n  - image_name: bar-baz\n    build_args: [\"BAR_BAZ_VERSION=1\"]\n"
      config_error(yaml).should eq "donico.yml: matrix[0].build_args[0] sets BAR_BAZ_VERSION, which donico sets itself (reserved: BUILD_DATE, DISTRO_NAME, BAR_BAZ_VERSION)"
      config_from("registry: r\nimage_name: foo\nmatrix:\n  - image_name: bar\n    build_args: [\"FOO_VERSION=1\"]\n")
        .matrix.first.build_args.should eq ["FOO_VERSION=1"]
    end

    # The dots of a version become dashes in the target name.
    it "refuses two rows that give the same bake target" do
      yaml = MINIMAL + "matrix:\n  - {distro: bookworm, version: \"1.0\"}\n  - {distro: bookworm, version: \"1-0\"}\n"
      config_error(yaml).should eq "donico.yml: matrix[1] and matrix[0] give the same bake target (bookworm-1-0)"
    end

    it "refuses a NUL character anywhere in the file" do
      config_error(MINIMAL + "matrix:\n  - build_args: [\"FOO=a\\0b\"]\n")
        .should eq "donico.yml: a value holds a NUL character"
      config_error(MINIMAL + "anything_else: \"a\\0b\"\n")
        .should eq "donico.yml: a value holds a NUL character"
    end
  end

  describe "#dockerfiles" do
    # `dockerfile` defaults to "Dockerfile": N distros would otherwise lint one file N times.
    it "returns each dockerfile once, in matrix order" do
      yaml = MINIMAL + <<-YAML
        matrix:
          - {version: "1", distro: a}
          - {version: "2", distro: b, dockerfile: Dockerfile.slim}
          - {version: "3", distro: c}
        YAML
      config_from(yaml).dockerfiles.should eq ["/app/Dockerfile", "/app/Dockerfile.slim"]
    end

    it "returns distinct dockerfiles all" do
      config_from(fixture("config/multiple_dockerfiles.yml")).dockerfiles.should eq(
        ["/app/dockerfiles/3.1/Dockerfile", "/app/dockerfiles/3.2/Dockerfile"])
    end
  end

  describe "#timestamp" do
    it "formats CI_COMMIT_TIMESTAMP in its own offset" do
      config_from(MINIMAL, {"CI_COMMIT_TIMESTAMP" => "2026-07-31T10:20:30+02:00"}).timestamp.should eq "20260731102030"
    end

    it "does not shift a UTC timestamp" do
      config_from(MINIMAL, {"CI_COMMIT_TIMESTAMP" => "2021-06-09T11:50:22Z"}).timestamp.should eq "20210609115022"
    end

    it "uses the date of the clock when the variable is unset" do
      config_from(MINIMAL).timestamp.should eq "20260731"
    end

    # An empty variable counts as unset (design section 7, item 10).
    it "uses the date of the clock when the variable is empty" do
      config_from(MINIMAL, {"CI_COMMIT_TIMESTAMP" => ""}).timestamp.should eq "20260731"
    end

    # Bad timestamp is reported on use: Config.load must still succeed.
    it "fails on use, not on load, with a one-line message" do
      config = config_from(MINIMAL, {"CI_COMMIT_TIMESTAMP" => "yesterday"})
      error = expect_raises(Donico::ConfigError) { config.timestamp }
      error.message.should eq %(CI_COMMIT_TIMESTAMP is not an ISO 8601 timestamp: "yesterday")
    end

    # The clock is the one of the Env the config was built from. (That the
    # value is computed once per run cannot be observed from here: an Env
    # holds a fixed instant, so two calls always read the same clock.)
    it "is the date of the clock of its own Env" do
      before_midnight = Time.utc(2026, 7, 31, 23, 59, 59)
      after_midnight = Time.utc(2026, 8, 1, 0, 0, 1)
      config_from(MINIMAL, now: before_midnight).timestamp.should eq "20260731"
      config_from(MINIMAL, now: after_midnight).timestamp.should eq "20260801"
    end

    it "rejects a month out of range as a bad timestamp" do
      config = config_from(MINIMAL, {"CI_COMMIT_TIMESTAMP" => "2026-13-45T10:00:00Z"})
      error = expect_raises(Donico::ConfigError) { config.timestamp }
      error.message.should eq %(CI_COMMIT_TIMESTAMP is not an ISO 8601 timestamp: "2026-13-45T10:00:00Z")
    end

    it "rejects an offset out of range as a bad timestamp" do
      config = config_from(MINIMAL, {"CI_COMMIT_TIMESTAMP" => "2026-07-31T10:20:30+99:00"})
      error = expect_raises(Donico::ConfigError) { config.timestamp }
      error.message.should eq %(CI_COMMIT_TIMESTAMP is not an ISO 8601 timestamp: "2026-07-31T10:20:30+99:00")
    end

    # Two GitLab pipelines of one commit share a runner's Docker daemon: under
    # the commit's date they would share the build tag, and the clean of one
    # would delete the image the other is testing. Every job of a pipeline
    # reads the same CI_PIPELINE_CREATED_AT.
    describe "under GitLab CI" do
      it "is the creation time of the pipeline, in its own offset" do
        config_from(MINIMAL, {"GITLAB_CI" => "true", "CI_PIPELINE_CREATED_AT" => "2026-11-22T05:40:26Z",
                              "CI_COMMIT_TIMESTAMP" => "2026-11-22T06:26:52+01:00"}).timestamp.should eq "20261122054026"
      end

      it "falls back on CI_COMMIT_TIMESTAMP when the creation time is unset or empty" do
        config_from(MINIMAL, {"GITLAB_CI" => "true", "CI_COMMIT_TIMESTAMP" => "2026-11-22T06:26:52+01:00"}).timestamp.should eq "20261122062652"
        config_from(MINIMAL, {"GITLAB_CI" => "true", "CI_PIPELINE_CREATED_AT" => "",
                              "CI_COMMIT_TIMESTAMP" => "2026-11-22T06:26:52+01:00"}).timestamp.should eq "20261122062652"
      end

      it "fails on use when the creation time is not ISO 8601" do
        config = config_from(MINIMAL, {"GITLAB_CI" => "true", "CI_PIPELINE_CREATED_AT" => "now"})
        error = expect_raises(Donico::ConfigError) { config.timestamp }
        error.message.should eq %(CI_PIPELINE_CREATED_AT is not an ISO 8601 timestamp: "now")
      end
    end

    # donico-action sets CI_PIPELINE_CREATED_AT to the time each job starts:
    # read outside GitLab CI, it would give build, test and push three tags.
    it "keeps the commit's date outside GitLab CI, whatever CI_PIPELINE_CREATED_AT holds" do
      config_from(MINIMAL, {"CI_PIPELINE_CREATED_AT" => "2026-11-22T05:40:26Z",
                            "CI_COMMIT_TIMESTAMP"    => "2026-11-22T06:26:52+01:00"}).timestamp.should eq "20261122062652"
      config_from(MINIMAL, {"GITLAB_CI" => "false", "CI_PIPELINE_CREATED_AT" => "2026-11-22T05:40:26Z",
                            "CI_COMMIT_TIMESTAMP" => "2026-11-22T06:26:52+01:00"}).timestamp.should eq "20261122062652"
    end
  end
end
