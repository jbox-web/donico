require "../spec_helper"

private FIXTURES = File.join(__DIR__, "..", "fixtures")

private HEADER = "# !!! THIS IS A GENERATED FILE !!! DON'T EDIT ME MANUALLY !!!\n" \
                 "# Instead edit donico.yml and run donico generate-files\n---\n"

private def rendered(yaml : String) : String
  with_project(yaml) { |env| return Donico::MatrixFile.render(Donico::Config.load(env)) }
  raise "unreachable"
end

describe Donico::MatrixFile do
  describe ".render" do
    # The expected files were produced by the Ruby gem (see the README of the
    # fixtures directory), never by this binary.
    {"minimal", "custom", "multiple_dockerfiles", "debian", "escaping", "quoted_versions"}.each do |name|
      it "renders spec/fixtures/bake/#{name}.yml exactly as the gem wrote it" do
        yaml = File.read(File.join(FIXTURES, "bake", "#{name}.yml"))
        expected = File.read(File.join(FIXTURES, "generated", "matrix", "#{name}.yml"))
        rendered(yaml).should eq expected
      end
    end

    it "renders one row" do
      yaml = "registry: r\nimage_name: foo\nmatrix:\n  - {version: \"1.31.8\", distro: trixie}\n"
      expected = HEADER + <<-YAML + "\n"
        ".matrix":
          parallel:
            matrix:
            - VERSION: 1.31.8
              DOCKER_DISTRO: trixie
        YAML
      rendered(yaml).should eq expected
    end

    it "renders an empty matrix as an empty list" do
      expected = HEADER + <<-YAML + "\n"
        ".matrix":
          parallel:
            matrix: []
        YAML
      rendered("registry: r\nimage_name: foo\nmatrix: []\n").should eq expected
    end

    it "quotes a version that would read back as a number" do
      yaml = "registry: r\nimage_name: foo\nmatrix:\n  - {version: \"3.10\", distro: \"18\"}\n"
      rendered(yaml).should contain "- VERSION: '3.10'\n      DOCKER_DISTRO: '18'\n"
    end

    # Config now refuses such values when the file loads (a distro and a
    # version only hold what a bake target accepts), so the writer is asked
    # directly: it still names the value it was given.
    it "names the value that cannot be written" do
      message = "donico.yml: matrix[1].distro cannot be written to the CI matrix file: it contains a line break"
      expect_raises(Donico::ConfigError, message) { Donico::MatrixFile.scalar("a\nb", "matrix[1].distro") }
      message = "donico.yml: matrix[0].version cannot be written to the CI matrix file: it is the YAML merge key"
      expect_raises(Donico::ConfigError, message) { Donico::MatrixFile.scalar("<<", "matrix[0].version") }
    end
  end

  describe ".scalar" do
    # One example per value; the expected text is the one Psych 5.3.1 writes.
    {
      "1.31.8", "latest", "trixie", "1e3", "1.5e3", "0o17", "0b2", "1__0", "foo:bar", "1.2.3-rc1",
    }.each do |value|
      it "writes #{value.inspect} bare" do
        Donico::MatrixFile.scalar(value).should eq value
      end
    end

    {
      "0.17", "18", "true", "null", "0x10", "1_000", "3.10", "1.0", "yes", "017", "08", "12:30",
      "2024-01-01", "1,000", "0b101", %("q"), "", "a: b", "a:", "a #b", "x ",
    }.each do |value|
      it "writes #{value.inspect} in single quotes" do
        Donico::MatrixFile.scalar(value).should eq "'#{value}'"
      end
    end

    {"y", "n", "~", ".5", "+1", "-1", "@foo", "#x", "- a", "'q'", " x"}.each do |value|
      it "writes #{value.inspect} in double quotes" do
        Donico::MatrixFile.scalar(value).should eq %("#{value}")
      end
    end

    # The branches of Psych's scalar scanner, one value on each side of each.
    # The expected text is what Psych 5.3.1 writes for the same string.
    {
      # A date is quoted only when it exists; a time only when it is one.
      "2024-02-28" => "'2024-02-28'", "2024-02-30" => "2024-02-30",
      "2024-01-01 10:00:00" => "'2024-01-01 10:00:00'", "2024-01-01 25:00:00" => "2024-01-01 25:00:00",
      # The words YAML 1.1 reads as a boolean or as nil, in any case.
      "No" => "'No'", "OFF" => "'OFF'", "on" => "'on'", "false" => "'false'", "Null" => "'Null'",
      "nope" => "nope", "offer" => "offer",
      # Sexagesimal numbers, with and without a fraction.
      "190:20:30" => "'190:20:30'", "1:2:3.5" => "'1:2:3.5'",
      # A first character that is not a word character: double quotes, unless
      # the value holds a double quote itself.
      ".inf" => %(".inf"), "-.INF" => %("-.INF"), ".NaN" => %(".NaN"), ":a" => %(":a"), "...x" => %("...x"),
      %(@a"b) => %('@a"b'), %(a"b) => %(a"b),
    }.each do |value, written|
      it "writes #{value.inspect} as #{written}" do
        Donico::MatrixFile.scalar(value).should eq written
      end
    end

    it "refuses the line breaks YAML knows besides the newline" do
      {"a\rb", "a\u0085b", "a\u2028b", "a\u2029b"}.each do |value|
        expect_raises(Donico::ConfigError, "it contains a line break") { Donico::MatrixFile.scalar(value) }
      end
    end

    it "refuses a byte order mark, which libyaml does not print" do
      expect_raises(Donico::ConfigError, "it contains a control character") { Donico::MatrixFile.scalar("a\uFEFFb") }
    end

    it "writes a capital Y and N in double quotes" do
      Donico::MatrixFile.scalar("Y").should eq %("Y")
      Donico::MatrixFile.scalar("N").should eq %("N")
    end

    it "doubles a single quote inside a single-quoted scalar" do
      Donico::MatrixFile.scalar("it's: x").should eq "'it''s: x'"
    end

    it "escapes a backslash inside a double-quoted scalar" do
      Donico::MatrixFile.scalar("@a\\b").should eq %("@a\\\\b")
    end

    it "writes the indicator-led values libyaml refuses as plain in single quotes" do
      Donico::MatrixFile.scalar(%([a"b)).should eq %('[a"b')
      Donico::MatrixFile.scalar(%(- a")).should eq %('- a"')
      Donico::MatrixFile.scalar(%(---")).should eq %('---"')
    end

    it "keeps ?\"x and -\"x bare: no space follows the indicator" do
      Donico::MatrixFile.scalar(%(?"x)).should eq %(?"x)
      Donico::MatrixFile.scalar(%(-"x)).should eq %(-"x)
    end

    it "rejects a space libyaml would fold in a double-quoted value" do
      # `@` forces double quotes; 63 more characters put the space at column 80 + 1.
      message = "donico.yml: matrix[0].version cannot be written to the CI matrix file: it holds a space past column 80, where YAML would fold the line"
      expect_raises(Donico::ConfigError, message) { Donico::MatrixFile.scalar("@" + "x" * 64 + " y", "matrix[0].version", 15) }
      value = "@" + "x" * 63 + " y"
      Donico::MatrixFile.scalar(value, "matrix[0].version", 15).should eq %("#{value}")
    end

    it "writes a character beyond the BMP escaped, in double quotes" do
      Donico::MatrixFile.scalar("a\u{1F600}").should eq %("a\\U0001F600")
    end

    # Psych folds a line at a space once the column before it passes 80
    # (measured on 5.3.1: a plain version of 65 characters then " y" stays on
    # one line after `    - VERSION: `, 66 characters is folded).
    it "accepts a space at column 80 of the line" do
      value = "x" * 65 + " y"
      Donico::MatrixFile.scalar(value, "matrix[0].version", 15).should eq value
    end

    it "rejects a space that libyaml would fold" do
      message = "donico.yml: matrix[0].version cannot be written to the CI matrix file: it holds a space past column 80, where YAML would fold the line"
      expect_raises(Donico::ConfigError, message) { Donico::MatrixFile.scalar("x" * 66 + " y", "matrix[0].version", 15) }
    end

    it "counts the opening quote of a quoted value in the column" do
      value = "a: " + "x" * 61 + " y"
      Donico::MatrixFile.scalar(value, "matrix[0].version", 15).should eq "'#{value}'"
      expect_raises(Donico::ConfigError) { Donico::MatrixFile.scalar("a: " + "x" * 62 + " y", "matrix[0].version", 15) }
    end

    it "rejects a line break" do
      message = "donico.yml: matrix[3].version cannot be written to the CI matrix file: it contains a line break"
      expect_raises(Donico::ConfigError, message) { Donico::MatrixFile.scalar("a\nb", "matrix[3].version") }
    end

    it "rejects a control character" do
      message = "donico.yml: matrix[0].distro cannot be written to the CI matrix file: it contains a control character"
      expect_raises(Donico::ConfigError, message) { Donico::MatrixFile.scalar("a\tb", "matrix[0].distro") }
    end

    it "rejects the merge key" do
      message = "donico.yml: matrix[0].distro cannot be written to the CI matrix file: it is the YAML merge key"
      expect_raises(Donico::ConfigError, message) { Donico::MatrixFile.scalar("<<", "matrix[0].distro") }
    end
  end
end
