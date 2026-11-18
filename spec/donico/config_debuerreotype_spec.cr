require "../spec_helper"

# The smallest project of the debuerreotype backend: no image name, no tag.
private ROOTFS = <<-YAML
  registry: harbor.example.org/debian
  image_builder: debuerreotype
  matrix:
    - distro: trixie
      version: "13"

  YAML

# One row with every key of the backend written.
private ROOTFS_FULL = <<-YAML
  registry: harbor.example.org/debian
  image_builder: debuerreotype
  apt_proxy: http://proxy.example.org:3142
  debuerreotype_image: harbor.example.org/base/debuerreotype:0.17
  matrix:
    - distro: jessie
      version: "8"
      archs: ["linux/amd64", "linux/386"]
      eol: true
      debootstrap_url: http://archive.debian.org/debian
      debootstrap_opts:
        - --debian-eol
        - --no-check-gpg
        - --keyring=/usr/share/keyrings/debian-archive-removed-keys.gpg
      timestamp: "20261117"

  YAML

private def config_from(yaml : String, vars : Hash(String, String) = {} of String => String) : Donico::Config
  with_project(yaml, vars: vars) { |env| return Donico::Config.load(env) }
  raise "unreachable"
end

private def config_error(yaml : String) : String?
  expect_raises(Donico::ConfigError) { config_from(yaml) }.message
end

# ROOTFS with `line` added to its one row.
private def row_error(line : String) : String?
  config_error(ROOTFS + "    #{line}\n")
end

describe Donico::Config do
  describe "image_builder: debuerreotype" do
    it "loads a row with a distro and a version alone, every other key at its default" do
      config = config_from(ROOTFS)

      config.image_builder.should eq "debuerreotype"
      config.debuerreotype?.should be_true
      config.apt_proxy.should be_nil
      config.debuerreotype_image.should be_nil
      entry = config.matrix.first
      entry.distro.should eq "trixie"
      entry.version.should eq "13"
      entry.archs.should eq ["linux/amd64"]
      entry.eol?.should be_false
      entry.debootstrap_url.should eq "http://deb.debian.org/debian"
      entry.debootstrap_opts.should eq ["--debian"]
      entry.timestamp.should be_nil
    end

    it "reads every key as written" do
      config = config_from(ROOTFS_FULL)

      config.apt_proxy.should eq "http://proxy.example.org:3142"
      config.debuerreotype_image.should eq "harbor.example.org/base/debuerreotype:0.17"
      entry = config.matrix.first
      entry.archs.should eq ["linux/amd64", "linux/386"]
      entry.eol?.should be_true
      entry.debootstrap_url.should eq "http://archive.debian.org/debian"
      entry.debootstrap_opts.should eq ["--debian-eol", "--no-check-gpg", "--keyring=/usr/share/keyrings/debian-archive-removed-keys.gpg"]
      entry.timestamp.should eq "20261117"
    end

    it "is not the bake backend" do
      config_from("registry: r\nimage_name: foo\n").debuerreotype?.should be_false
    end

    it "accepts an empty debootstrap_opts list" do
      config_from(ROOTFS + "    debootstrap_opts: []\n").matrix.first.debootstrap_opts.should eq [] of String
    end

    # A bake row needs neither: these keys belong to the other backend there.
    it "ignores its own keys under the bake backend, whatever they hold" do
      yaml = "registry: r\nimage_name: foo\napt_proxy: [1]\ndebuerreotype_image: {a: b}\n" \
             "matrix:\n  - version: \"1\"\n    eol: maybe\n    debootstrap_url: [x]\n    debootstrap_opts: 3\n    timestamp: 5\n"
      config = config_from(yaml)

      config.image_builder.should eq "bake"
      config.matrix.first.version.should eq "1"
    end

    it "ignores the keys of the bake backend, whatever they hold" do
      yaml = ROOTFS + "    image_name: \"a b\"\n    tags: 3\n    build_args: [NOEQUAL]\n    dockerfile: \"\"\n" \
                      "    secret_envs: x\n    test_variants: 1\n    login_env: {}\n    test_args: 2\nimage_name: \"not a name\"\n"
      config = config_from(yaml)

      config.matrix.first.distro.should eq "trixie"
    end
  end

  describe "the default timestamp of the debuerreotype backend" do
    it "is the day before the clock, whatever CI_COMMIT_TIMESTAMP holds" do
      config = config_from(ROOTFS, vars: {"CI_COMMIT_TIMESTAMP" => "2026-01-02T03:04:05Z"})

      # with_project runs at 2026-07-31 23:59:59 UTC.
      config.rootfs_timestamp.should eq "20260730"
    end

    # The jobs of one pipeline share its creation time: `build` before
    # midnight and `push` after it still name the same tarballs.
    it "is the day before the pipeline was created under GitLab CI, in the offset of that time" do
      config_from(ROOTFS, vars: {"CI_PIPELINE_CREATED_AT" => "2026-11-17T23:50:00+01:00"}).rootfs_timestamp.should eq "20261116"
      config_from(ROOTFS, vars: {"CI_PIPELINE_CREATED_AT" => "2026-11-18T00:10:00Z"}).rootfs_timestamp.should eq "20261117"
      config_from(ROOTFS, vars: {"CI_PIPELINE_CREATED_AT" => "2026-03-01T00:00:00+00:00"}).rootfs_timestamp.should eq "20260228"
    end

    it "falls back on the clock when CI_PIPELINE_CREATED_AT is empty" do
      config_from(ROOTFS, vars: {"CI_PIPELINE_CREATED_AT" => ""}).rootfs_timestamp.should eq "20260730"
    end

    it "refuses a CI_PIPELINE_CREATED_AT that is not a timestamp, when a row needs it" do
      config = config_from(ROOTFS, vars: {"CI_PIPELINE_CREATED_AT" => "yesterday"})

      expect_raises(Donico::ConfigError, %(CI_PIPELINE_CREATED_AT is not an ISO 8601 timestamp: "yesterday")) do
        config.rootfs_timestamp
      end
    end

    it "crosses a month" do
      with_project(ROOTFS, now: Time.utc(2026, 3, 1, 0, 0, 0)) do |env|
        Donico::Config.load(env).rootfs_timestamp.should eq "20260228"
      end
    end
  end

  describe "the APT proxy in use" do
    it "is apt_proxy when the key is set" do
      config_from(ROOTFS_FULL).build_proxy.should eq "http://proxy.example.org:3142"
    end

    it "is none without the key" do
      config_from(ROOTFS).build_proxy.should be_nil
    end

    it "is none when ENABLE_APT_PROXY is false" do
      config_from(ROOTFS_FULL, vars: {"ENABLE_APT_PROXY" => "false"}).build_proxy.should be_nil
    end

    it "stays in use for any other value of ENABLE_APT_PROXY" do
      {"true", "", "0", "no", "FALSE"}.each do |value|
        config_from(ROOTFS_FULL, vars: {"ENABLE_APT_PROXY" => value}).build_proxy.should eq "http://proxy.example.org:3142"
      end
    end

    it "is none for an empty apt_proxy" do
      config_from(ROOTFS + "apt_proxy: \"\"\n").build_proxy.should be_nil
    end
  end

  describe "what the debuerreotype backend refuses" do
    it "needs a matrix" do
      config_error("registry: r\nimage_builder: debuerreotype\n").should eq(
        "donico.yml: matrix is required with image_builder: debuerreotype")
    end

    it "needs a registry" do
      config_error("image_builder: debuerreotype\nmatrix:\n  - {distro: trixie, version: \"13\"}\n").should eq(
        "donico.yml: missing required key: registry")
    end

    it "needs a distro on every row" do
      config_error("registry: r\nimage_builder: debuerreotype\nmatrix:\n  - {distro: trixie, version: \"13\"}\n  - {version: \"12\"}\n").should eq(
        "donico.yml: matrix[1].distro is required with image_builder: debuerreotype")
    end

    it "needs a version on every row" do
      config_error("registry: r\nimage_builder: debuerreotype\nmatrix:\n  - {distro: trixie}\n").should eq(
        %(donico.yml: matrix[0].version is required with image_builder: debuerreotype (the Debian major, quoted: "13")))
    end

    it "refuses an unquoted version" do
      config_error("registry: r\nimage_builder: debuerreotype\nmatrix:\n  - {distro: trixie, version: 13}\n").should eq(
        "donico.yml: matrix[0].version must be a quoted string (YAML read it as 13; quote it as written in the file)")
    end

    # Only the platforms whose Debian architecture donico knows: any other
    # one would be built for minutes, or fail in debootstrap on a name Debian
    # does not have (`arm`, whose variant decides between armel and armhf).
    it "refuses an arch that is not one of the supported platforms" do
      supported = "(supported: linux/amd64, linux/arm64, linux/386, linux/ppc64le, linux/s390x, linux/riscv64, linux/mips64le)"
      row_error(%(archs: ["linux/amd64", "amd64"])).should eq(
        %(donico.yml: matrix[0].archs[1] "amd64" is invalid #{supported}))
      ["linux/arm/v7", "linux/arm", "linux/", "windows/amd64", "linux/i386", "linux/ppc64el"].each do |arch|
        row_error(%(archs: ["#{arch}"])).should eq(%(donico.yml: matrix[0].archs[0] "#{arch}" is invalid #{supported}))
      end
    end

    it "accepts every supported platform" do
      archs = ["linux/amd64", "linux/arm64", "linux/386", "linux/ppc64le", "linux/s390x", "linux/riscv64", "linux/mips64le"]
      config_from(ROOTFS + "    archs: #{archs.inspect}\n").matrix.first.archs.should eq archs
    end

    # The distro names the image, and docker refuses an upper-case repository;
    # with the arch it names what `clean` removes, where a dash would let one
    # row match the leftovers of another.
    it "refuses a distro that is not a Debian codename" do
      ["Trixie", "trixie-backports", "trixie_1", "trixie.1"].each do |distro|
        config_error("registry: r\nimage_builder: debuerreotype\nmatrix:\n  - {distro: #{distro}, version: \"13\"}\n").should eq(
          %(donico.yml: matrix[0].distro "#{distro}" is invalid (a Debian codename: lower-case letters and digits)))
      end
    end

    it "refuses an empty list of archs" do
      row_error("archs: []").should eq "donico.yml: matrix[0].archs must not be empty"
    end

    it "refuses an arch given twice" do
      row_error(%(archs: ["linux/amd64", "linux/arm64", "linux/amd64"])).should eq(
        "donico.yml: matrix[0].archs[2] repeats linux/amd64")
    end

    it "refuses an eol that is not a boolean" do
      row_error("eol: maybe").should eq "donico.yml: matrix[0].eol must be true or false"
      row_error(%(eol: "true")).should eq "donico.yml: matrix[0].eol must be true or false"
    end

    it "refuses an unquoted timestamp" do
      row_error("timestamp: 20261117").should eq(
        "donico.yml: matrix[0].timestamp must be a quoted string (YAML read it as 20261117; quote it as written in the file)")
    end

    it "refuses a timestamp a tag or a file name cannot carry" do
      ["2026 11", "", ".nightly", "-x", "a" * 129].each do |timestamp|
        row_error(%(timestamp: "#{timestamp}")).should eq(
          %(donico.yml: matrix[0].timestamp "#{timestamp}" is invalid (a docker tag: letters, digits, ., _ and -, not starting with . or -, 128 characters at most)))
      end
    end

    it "accepts a timestamp of 128 characters, and one that starts with an underscore" do
      config_from(ROOTFS + "    timestamp: \"#{"a" * 128}\"\n").matrix.first.timestamp.should eq "a" * 128
      config_from(ROOTFS + "    timestamp: \"_nightly.1-a\"\n").matrix.first.timestamp.should eq "_nightly.1-a"
    end

    # Every one of these values is written into the script bash runs in the
    # build container: a space, a quote or a `;` there is another command.
    # The value is not quoted in the message: a URL may carry credentials.
    it "refuses a debootstrap_url the build script cannot carry" do
      ["http://a b", "http://a;id", "$(id)", "`id`", "a'b", "a\"b", "a|b", "a&b", "a>b", "a*", "a\\nb", ""].each do |url|
        row_error("debootstrap_url: #{url.inspect}").should eq(
          "donico.yml: matrix[0].debootstrap_url holds a character the build script cannot carry (allowed: letters, digits and _ @ % + = : , . / -)")
      end
    end

    it "refuses a debootstrap_opts item the build script cannot carry" do
      row_error(%(debootstrap_opts: ["--debian", "--include=a b"])).should eq(
        "donico.yml: matrix[0].debootstrap_opts[1] holds a character the build script cannot carry (allowed: letters, digits and _ @ % + = : , . / -)")
    end

    it "refuses a debootstrap_opts that is not a list of strings" do
      row_error("debootstrap_opts: --debian").should eq "donico.yml: matrix[0].debootstrap_opts must be a list of strings"
    end

    it "refuses an apt_proxy the build script cannot carry" do
      config_error(ROOTFS + "apt_proxy: \"http://proxy; id\"\n").should eq(
        "donico.yml: apt_proxy holds a character the build script cannot carry (allowed: letters, digits and _ @ % + = : , . / -)")
    end

    it "accepts a proxy with credentials and a port" do
      config_from(ROOTFS + "apt_proxy: http://user:p%40ss@proxy.example.org:3142/\n").apt_proxy.should eq "http://user:p%40ss@proxy.example.org:3142/"
    end

    it "refuses a non-string apt_proxy or debuerreotype_image" do
      config_error(ROOTFS + "apt_proxy: 1\n").should eq "donico.yml: apt_proxy must be a string"
      config_error(ROOTFS + "debuerreotype_image: [a]\n").should eq "donico.yml: debuerreotype_image must be a string"
    end

    # The image, the build directories and the tarballs are named after the
    # distro alone.
    it "refuses two rows of one distro" do
      yaml = "registry: r\nimage_builder: debuerreotype\nmatrix:\n  - {distro: trixie, version: \"13\"}\n  - {distro: bookworm, version: \"12\"}\n  - {distro: trixie, version: \"14\"}\n"
      config_error(yaml).should eq "donico.yml: matrix[2] and matrix[0] build the same image (trixie)"
    end

    it "keeps every message on one line" do
      [
        config_error("registry: r\nimage_builder: debuerreotype\n"),
        row_error("eol: maybe"),
        row_error(%(archs: ["amd64"])),
        row_error(%(debootstrap_url: "a b")),
      ].each(&.to_s.should_not(contain('\n')))
    end
  end
end
