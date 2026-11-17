require "../spec_helper"

private FIXTURES = File.join(__DIR__, "..", "fixtures")

private def bakefile_of(fixture : String) : String
  yaml = File.read(File.join(FIXTURES, "bake", fixture))
  with_project(yaml, vars: {"CI_COMMIT_TIMESTAMP" => "2026-07-31T00:00:00Z"}) do |env|
    return Donico::Bakefile.render(Donico::Image.all(Donico::Config.load(env)))
  end
  raise "unreachable"
end

describe Donico::Bakefile do
  describe ".render" do
    # The expected files were written by the Ruby gem, not by this binary:
    # see spec/fixtures/generated/bakefile/README.md.
    {"minimal", "custom", "multiple_dockerfiles", "debian", "escaping"}.each do |name|
      it "renders spec/fixtures/bake/#{name}.yml exactly as the gem wrote it" do
        expected = File.read(File.join(FIXTURES, "generated", "bakefile", "#{name}.txt"))
        bakefile_of("#{name}.yml").should eq expected
      end
    end

    # Build arg values go inside quoted HCL strings: an unescaped quote or
    # backslash yields a file that only fails at the next build.
    it "escapes double quotes in a build arg" do
      bakefile_of("escaping.yml").scan(%(MOTD = "say \\"hi\\"")).size.should eq 2
    end

    it "escapes backslashes in a build arg" do
      bakefile_of("escaping.yml").scan(%(WINPATH = "C:\\\\tmp")).size.should eq 2
    end

    it "writes the platforms as a Ruby list of strings" do
      yaml = "registry: r\nimage_name: foo\nmatrix:\n  - {version: \"1\", distro: a, archs: [\"linux/amd64\", \"linux/arm64\"]}\n"
      with_project(yaml) do |env|
        out = Donico::Bakefile.render(Donico::Image.all(Donico::Config.load(env)))
        out.should contain %(  platforms = ["linux/amd64", "linux/arm64"]\n)
      end
    end

    it "escapes a quote and a backslash in a platform like Array#inspect" do
      yaml = "registry: r\nimage_name: foo\nmatrix:\n  - {version: \"1\", distro: a, archs: [\"a\\\"b\", \"c\\\\d\"]}\n"
      with_project(yaml) do |env|
        out = Donico::Bakefile.render(Donico::Image.all(Donico::Config.load(env)))
        out.should contain %(  platforms = ["a\\"b", "c\\\\d"]\n)
      end
    end

    it "writes a control character and an interpolation marker like Array#inspect" do
      yaml = <<-'YAML'
        registry: r
        image_name: foo
        matrix:
          - version: "1"
            distro: a
            archs: ["a\u0001b", '#{x}']
        YAML
      with_project(yaml) do |env|
        out = Donico::Bakefile.render(Donico::Image.all(Donico::Config.load(env)))
        out.should contain %q(  platforms = ["a\u0001b", "\#{x}"]) + "\n"
      end
    end

    # A build arg is a value, never an HCL template: `${NAME}` in it used to
    # make bake look for a variable of that name.
    it "writes ${ and %{ of a build arg literally, in both targets" do
      yaml = <<-YAML
        registry: r
        image_name: foo
        matrix:
          - version: "1"
            distro: a
            build_args: ['GREETING=hello ${HOME} 100%{x}']
        YAML
      with_project(yaml) do |env|
        out = Donico::Bakefile.render(Donico::Image.all(Donico::Config.load(env)))
        out.scan(%q(    GREETING = "hello $${HOME} 100%%{x}")).size.should eq 2
      end
    end

    it "escapes the dockerfile path, in both targets" do
      yaml = <<-YAML
        registry: r
        image_name: foo
        matrix:
          - version: "1"
            distro: a
            dockerfile: 'dir/a"b ${x}'
        YAML
      with_project(yaml) do |env|
        out = Donico::Bakefile.render(Donico::Image.all(Donico::Config.load(env)))
        out.scan(%q(  dockerfile = "dir/a\"b $${x}")).size.should eq 2
      end
    end

    it "renders secrets, escaped, before the platforms" do
      yaml = <<-YAML
        registry: r
        image_name: foo
        matrix:
          - version: "1"
            distro: a
            secret_envs:
              - id: TOKEN
            secret_files:
              - id: aws
                src: "${HOME}/.aws/credentials"
        YAML
      with_project(yaml) do |env|
        out = Donico::Bakefile.render(Donico::Image.all(Donico::Config.load(env)))
        block = "  secret = [\n    {\n      type = \"env\"\n      id = \"TOKEN\"\n    },\n" \
                "    {\n      type = \"file\"\n      id = \"aws\"\n      src = \"${HOME}/.aws/credentials\"\n    },\n  ]\n"
        out.should contain block
      end
    end

    it "escapes a quote and a backslash in a secret id and src" do
      yaml = <<-YAML
        registry: r
        image_name: foo
        matrix:
          - version: "1"
            distro: a
            secret_files:
              - id: 'a"b\\c'
                src: 'C:\\x"y'
        YAML
      with_project(yaml) do |env|
        out = Donico::Bakefile.render(Donico::Image.all(Donico::Config.load(env)))
        out.should contain %q(      id = "a\"b\\c")
        out.should contain %q(      src = "C:\\x\"y")
      end
    end
  end
end
