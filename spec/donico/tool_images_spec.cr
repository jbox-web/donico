require "../spec_helper"

private def tools_from(yaml : String) : Donico::ToolImages
  with_project(yaml) { |env| return Donico::ToolImages.from(Donico::Config.load(env)) }
  raise "unreachable"
end

private MINIMAL = "registry: r.example/base\nimage_name: foo\n"

describe Donico::ToolImages do
  it "derives both images from registry alone" do
    tools = tools_from(MINIMAL)
    tools.docker_linter.should eq "r.example/base/hadolint:latest"
    tools.inspec.should eq "r.example/base/inspec:latest"
  end

  it "moves both images with tools_registry" do
    tools = tools_from(MINIMAL + "tools_registry: t.example/tools\n")
    tools.docker_linter.should eq "t.example/tools/hadolint:latest"
    tools.inspec.should eq "t.example/tools/inspec:latest"
  end

  it "lets docker_linter win for the linter only" do
    tools = tools_from(MINIMAL + "docker_linter: x.example/lint:1\n")
    tools.docker_linter.should eq "x.example/lint:1"
    tools.inspec.should eq "r.example/base/inspec:latest"
  end

  it "lets inspec_image win for Inspec only" do
    tools = tools_from(MINIMAL + "tools_registry: t.example/tools\ninspec_image: x.example/insp:2\n")
    tools.inspec.should eq "x.example/insp:2"
    tools.docker_linter.should eq "t.example/tools/hadolint:latest"
  end

  describe "the debuerreotype image" do
    rootfs = "registry: r.example/debian\nimage_builder: debuerreotype\nmatrix:\n  - {distro: trixie, version: \"13\"}\n"

    it "lives under registry by default" do
      tools_from(rootfs).debuerreotype.should eq "r.example/debian/debuerreotype:latest"
    end

    it "moves with tools_registry" do
      tools_from(rootfs + "tools_registry: t.example/tools\n").debuerreotype.should eq "t.example/tools/debuerreotype:latest"
    end

    it "is debuerreotype_image when the key is set" do
      tools = tools_from(rootfs + "tools_registry: t.example/tools\ndebuerreotype_image: x.example/base/debuerreotype:0.17\n")
      tools.debuerreotype.should eq "x.example/base/debuerreotype:0.17"
      tools.inspec.should eq "t.example/tools/inspec:latest"
    end
  end
end
