require "../spec_helper"

private FIXTURES = File.join(__DIR__, "..", "fixtures", "debuerreotype")

private HEAD = "registry: harbor.example.org/debian\nimage_builder: debuerreotype\n"

private def rootfs_from(yaml : String, vars : Hash(String, String) = {} of String => String) : Donico::Rootfs
  with_project(yaml, vars: vars) { |env| return Donico::Rootfs.all(Donico::Config.load(env)).first }
  raise "unreachable"
end

# The script danico's Rakefile built from templates/debian-build.erb for the
# same row and arch (see spec/fixtures/debuerreotype/README.md).
private def reference(name : String) : String
  File.read(File.join(FIXTURES, "#{name}.sh"))
end

private TRIXIE = HEAD + "matrix:\n  - distro: trixie\n    version: \"13\"\n    archs: [\"linux/amd64\", \"linux/arm64\"]\n"

describe Donico::Rootfs do
  describe "#script, against the scripts rendered by Ruby from the original template" do
    it "renders a row with every default and no proxy" do
      (rootfs_from(TRIXIE).script("amd64") + "\n").should eq reference("trixie")
    end

    it "renders the proxy lines when apt_proxy is in use" do
      rootfs = rootfs_from(TRIXIE + "apt_proxy: http://proxy.example.org:3142\n")
      (rootfs.script("arm64") + "\n").should eq reference("trixie-proxy")
    end

    it "renders the row without the proxy when ENABLE_APT_PROXY is false" do
      rootfs = rootfs_from(TRIXIE + "apt_proxy: http://proxy.example.org:3142\n", vars: {"ENABLE_APT_PROXY" => "false"})
      (rootfs.script("amd64") + "\n").should eq reference("trixie")
    end

    it "renders an end-of-life row, with its debootstrap URL and options" do
      yaml = HEAD + <<-YAML
        matrix:
          - distro: jessie
            version: "8"
            eol: true
            debootstrap_url: http://archive.debian.org/debian
            debootstrap_opts:
              - --debian-eol
              - --no-check-gpg
              - --keyring=/usr/share/keyrings/debian-archive-removed-keys.gpg

        YAML
      (rootfs_from(yaml).script("amd64") + "\n").should eq reference("jessie-eol")
    end

    it "gives debootstrap i386 for the arch 386, and keeps 386 in the build directory" do
      yaml = HEAD + "matrix:\n  - distro: bullseye\n    version: \"11\"\n    archs: [\"linux/amd64\", \"linux/386\"]\n"
      (rootfs_from(yaml).script("386") + "\n").should eq reference("bullseye-386")
    end

    # Beyond danico's map (386 alone): the other platforms docker and Debian
    # name differently. No Ruby fixture exists for them.
    it "gives debootstrap the Debian name of every supported arch" do
      archs = ["linux/amd64", "linux/arm64", "linux/386", "linux/ppc64le", "linux/s390x", "linux/riscv64", "linux/mips64le"]
      rootfs = rootfs_from(HEAD + "matrix:\n  - distro: trixie\n    version: \"13\"\n    archs: #{archs.inspect}\n")
      debian = {"amd64" => "amd64", "arm64" => "arm64", "386" => "i386", "ppc64le" => "ppc64el", "s390x" => "s390x", "riscv64" => "riscv64", "mips64le" => "mips64el"}

      rootfs.archs.should eq debian.keys
      debian.each do |docker, name|
        rootfs.script(docker).should start_with "debuerreotype-init --arch=#{name} --debian --non-debian trixie-#{docker}-20260730 trixie "
      end
    end

    it "is one line, without a comment" do
      script = rootfs_from(TRIXIE).script("amd64")
      script.should_not contain '\n'
      script.should_not contain '#'
      script.should start_with "debuerreotype-init --arch=amd64 --debian --non-debian trixie-amd64-20260730 trixie http://deb.debian.org/debian;"
      script.should end_with ";sha256sum trixie-amd64-20260730.tar;ls -hal"
    end
  end

  describe "the names derived from a row" do
    it "takes the archs from the platforms, in the order of the file" do
      rootfs = rootfs_from(HEAD + "matrix:\n  - distro: trixie\n    version: \"13\"\n    archs: [\"linux/arm64\", \"linux/386\", \"linux/amd64\"]\n")
      rootfs.archs.should eq ["arm64", "386", "amd64"]
      rootfs.platforms.should eq "linux/arm64,linux/386,linux/amd64"
    end

    it "names the build directory and the tarball after the distro, the arch and the timestamp" do
      rootfs = rootfs_from(TRIXIE)
      rootfs.build_dir("arm64").should eq "trixie-arm64-20260730"
      rootfs.tarball("arm64").should eq "build/trixie-arm64-20260730.tar"
    end

    it "uses the timestamp of the row when it has one" do
      rootfs = rootfs_from(TRIXIE + "    timestamp: \"20261117\"\n")
      rootfs.timestamp.should eq "20261117"
      rootfs.build_dir("amd64").should eq "trixie-amd64-20261117"
      rootfs.script("amd64").should contain "debuerreotype-tar trixie-amd64-20261117 trixie-amd64-20261117.tar;"
    end

    it "does not read CI_PIPELINE_CREATED_AT when the row has a timestamp" do
      rootfs = rootfs_from(TRIXIE + "    timestamp: \"20261117\"\n", vars: {"CI_PIPELINE_CREATED_AT" => "nonsense"})
      rootfs.timestamp.should eq "20261117"
    end

    it "defaults the timestamp to the day before the run" do
      rootfs_from(TRIXIE).timestamp.should eq "20260730"
    end

    it "names the image after the registry and the distro" do
      rootfs_from(TRIXIE).image.should eq "harbor.example.org/debian/trixie"
    end

    it "tags latest, the Debian major, the full Debian version and the timestamp, in that order" do
      rootfs_from(TRIXIE).tags("13.2").should eq [
        "harbor.example.org/debian/trixie:latest",
        "harbor.example.org/debian/trixie:13",
        "harbor.example.org/debian/trixie:13.2",
        "harbor.example.org/debian/trixie:20260730",
      ]
    end

    it "has the task prefix of any row" do
      rootfs_from(TRIXIE).task_prefix.should eq "trixie:13"
    end

    it "gives one Rootfs per row" do
      yaml = HEAD + "matrix:\n  - {distro: trixie, version: \"13\"}\n  - {distro: bookworm, version: \"12\"}\n"
      with_project(yaml) do |env|
        Donico::Rootfs.all(Donico::Config.load(env)).map(&.distro).should eq ["trixie", "bookworm"]
      end
    end
  end
end
