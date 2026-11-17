require "../spec_helper"

# One matrix row on its own, built from the text of a YAML mapping. Index 0
# unless a spec says otherwise: it only shows in error paths.
private def entry_from(yaml : String, index : Int32 = 0) : Donico::MatrixEntry
  Donico::MatrixEntry.new(YAML.parse(yaml).as_h, index)
end

private def entry_error(yaml : String, index : Int32 = 0) : String?
  expect_raises(Donico::ConfigError) { entry_from(yaml, index) }.message
end

describe Donico::MatrixEntry do
  describe "defaults" do
    it "fills every key of an empty row" do
      entry = entry_from("{}")
      entry.image_name.should be_nil
      entry.version.should eq "latest"
      entry.distro.should eq "buster"
      entry.archs.should eq ["linux/amd64"]
      entry.dockerfile.should eq "Dockerfile"
      entry.build_args.should eq [] of String
      entry.test_args.should eq [] of String
      entry.secret_envs.should eq [] of Hash(String, String)
      entry.secret_files.should eq [] of Hash(String, String)
      entry.tags.should eq ["%<version>s-%<distro>s"]
      entry.test_variants.should eq [] of Array(String)
      entry.login_env.should eq [] of String
    end
  end

  describe "values" do
    it "reads every key as written" do
      entry = entry_from(<<-YAML)
        image_name: bookworm
        version: "1.0.0"
        distro: trixie
        archs: [linux/amd64, linux/arm64]
        dockerfile: foo/Dockerfile
        build_args: [NODEJS_VERSION=14.17.3]
        test_args: [RUBYGEM_VERSION=3.2.24]
        tags: [latest, "%<version>s"]
        test_variants:
          - ["run_mode=default"]
          - ["run_mode=dind", "x=y"]
        login_env: [REGISTRY_TOKEN]
        YAML
      entry.image_name.should eq "bookworm"
      entry.version.should eq "1.0.0"
      entry.distro.should eq "trixie"
      entry.archs.should eq ["linux/amd64", "linux/arm64"]
      entry.dockerfile.should eq "foo/Dockerfile"
      entry.build_args.should eq ["NODEJS_VERSION=14.17.3"]
      entry.test_args.should eq ["RUBYGEM_VERSION=3.2.24"]
      entry.tags.should eq ["latest", "%<version>s"]
      entry.test_variants.should eq [["run_mode=default"], ["run_mode=dind", "x=y"]]
      entry.login_env.should eq ["REGISTRY_TOKEN"]
    end

    it "keeps an unquoted dotted version that is not a number" do
      entry_from("version: 1.0.0").version.should eq "1.0.0"
    end

    it "treats a null value as absent" do
      entry_from("{version: , distro: }").distro.should eq "buster"
    end
  end

  describe "version" do
    it "keeps a quoted version untouched" do
      entry_from(%(version: "3.10")).version.should eq "3.10"
    end

    it "rejects a float and says what to write" do
      entry_error("version: 3.10", 2).should eq(
        %(donico.yml: matrix[2].version must be a quoted string (YAML read it as 3.1; quote it as written in the file)))
    end

    it "rejects an integer" do
      entry_error("version: 3").should eq(
        %(donico.yml: matrix[0].version must be a quoted string (YAML read it as 3; quote it as written in the file)))
    end

    # Crystal types 1e3 as a number where Ruby keeps a string: design section 7, item 16.
    it "rejects the exponent form 1e3" do
      entry_error("version: 1e3").should eq(
        %(donico.yml: matrix[0].version must be a quoted string (YAML read it as 1000.0; quote it as written in the file)))
    end

    # The converse difference: Crystal keeps 12:30 as a string where Ruby
    # reads a number. It is refused all the same, for its colon: a version is
    # a part of the bake target and of the build tag.
    it "rejects the unquoted form 12:30, for its colon" do
      entry_error("version: 12:30").should eq(
        %(donico.yml: matrix[0].version "12:30" is invalid (allowed: letters, digits, ., _ and -)))
    end
  end

  describe "wrong types" do
    it "rejects a number for image_name and for dockerfile" do
      entry_error("image_name: 2048").should eq "donico.yml: matrix[0].image_name must be a string"
      entry_error("dockerfile: 1").should eq "donico.yml: matrix[0].dockerfile must be a string"
    end

    it "rejects tags and test_variants that are not lists" do
      entry_error("tags: latest").should eq "donico.yml: matrix[0].tags must be a list of strings"
      entry_error("test_variants: fast").should eq "donico.yml: matrix[0].test_variants must be a list of lists of strings"
    end

    it "rejects a secret whose key is not a string, and counts a null value as missing" do
      entry_error("secret_envs: [{1: x}]").should eq "donico.yml: matrix[0].secret_envs[0] must have string keys"
      entry_error("secret_files: [{id: aws, src: ~}]").should eq "donico.yml: matrix[0].secret_files[0] is missing required key: src"
    end

    it "rejects a number for distro" do
      entry_error("distro: 12", 1).should eq "donico.yml: matrix[1].distro must be a string"
    end

    it "rejects a scalar for archs" do
      entry_error("archs: linux/amd64").should eq "donico.yml: matrix[0].archs must be a list of strings"
    end

    it "rejects an unquoted number inside build_args" do
      entry_error("build_args: [FOO=1, 2]").should eq "donico.yml: matrix[0].build_args must be a list of strings"
    end

    it "rejects a non-string item in test_args" do
      entry_error("test_args: [true]").should eq "donico.yml: matrix[0].test_args must be a list of strings"
    end

    it "rejects a non-string item in tags" do
      entry_error("tags: [1.5]").should eq "donico.yml: matrix[0].tags must be a list of strings"
    end

    it "rejects a mapping for secret_envs" do
      entry_error("secret_envs: {id: X}").should eq "donico.yml: matrix[0].secret_envs must be a list of mappings"
    end

    it "rejects a scalar item in secret_files" do
      entry_error("secret_files: [aws]").should eq "donico.yml: matrix[0].secret_files must be a list of mappings"
    end

    it "rejects a non-string value inside a secret" do
      entry_error("secret_envs: [{id: 12}]").should eq "donico.yml: matrix[0].secret_envs[0].id must be a string"
    end
  end

  describe "build_args" do
    it "rejects an item without a separator, naming its index" do
      entry_error("build_args: [FOO=1, BAR]", 3).should eq "donico.yml: matrix[3].build_args[1] must be KEY=VALUE"
    end

    it "rejects an item whose key is empty" do
      entry_error("build_args: [=x]").should eq "donico.yml: matrix[0].build_args[0] must be KEY=VALUE"
    end

    it "accepts an empty value and a value containing a separator" do
      entry_from(%(build_args: ["A=", "B=c=d"])).build_args.should eq ["A=", "B=c=d"]
    end

    it "accepts a test_args item without a separator" do
      entry_from("test_args: [FLAG]").test_args.should eq ["FLAG"]
    end
  end

  describe "test_variants and login_env" do
    it "rejects a flat list for test_variants" do
      entry_error("test_variants: [run_mode=default]").should eq(
        "donico.yml: matrix[0].test_variants must be a list of lists of strings")
    end

    it "rejects a non-string item in a variant" do
      entry_error("test_variants: [[1]]").should eq(
        "donico.yml: matrix[0].test_variants must be a list of lists of strings")
    end

    it "rejects a scalar for login_env" do
      entry_error("login_env: TOKEN").should eq "donico.yml: matrix[0].login_env must be a list of strings"
    end

    it "rejects a non-string item in login_env" do
      entry_error("login_env: [1]").should eq "donico.yml: matrix[0].login_env must be a list of strings"
    end
  end

  # An id-less secret used to render as `id = ""`: valid HCL that mounts nothing.
  describe "secrets" do
    it "rejects a secret env without an id" do
      entry_error("secret_envs: [{src: x}]").should eq(
        "donico.yml: matrix[0].secret_envs[0] is missing required key: id")
    end

    it "rejects a secret file without an id" do
      entry_error("secret_files: [{src: x}]").should eq(
        "donico.yml: matrix[0].secret_files[0] is missing required key: id")
    end

    it "rejects a secret file without a src" do
      entry_error("secret_files: [{id: aws}]", 3).should eq(
        "donico.yml: matrix[3].secret_files[0] is missing required key: src")
    end

    it "names both keys when a secret file declares neither" do
      entry_error("secret_files: [{}]").should eq(
        "donico.yml: matrix[0].secret_files[0] is missing required keys: id, src")
    end

    it "reports the index of the faulty entry" do
      entry_error("secret_envs: [{id: A}, {id: B}, {}]").should eq(
        "donico.yml: matrix[0].secret_envs[2] is missing required key: id")
    end

    it "counts an empty id as missing" do
      entry_error(%(secret_envs: [{id: ""}])).should eq(
        "donico.yml: matrix[0].secret_envs[0] is missing required key: id")
    end

    it "accepts fully declared secrets" do
      entry = entry_from(<<-YAML)
        secret_envs: [{id: GITHUB_TOKEN}]
        secret_files: [{id: aws, src: /tmp/creds}]
        YAML
      entry.secret_envs.should eq [{"id" => "GITHUB_TOKEN"}]
      entry.secret_files.should eq [{"id" => "aws", "src" => "/tmp/creds"}]
    end
  end
end
