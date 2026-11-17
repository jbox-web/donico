require "../spec_helper"

describe Donico::Dotenv do
  describe ".parse" do
    it "reads a plain assignment" do
      Donico::Dotenv.parse("A=1\n").should eq({"A" => "1"})
    end

    it "accepts an export prefix" do
      Donico::Dotenv.parse("export A=1\n").should eq({"A" => "1"})
    end

    it "unwraps double quotes" do
      Donico::Dotenv.parse(%(A="x y"\n)).should eq({"A" => "x y"})
    end

    it "unwraps single quotes" do
      Donico::Dotenv.parse("A='x y'\n").should eq({"A" => "x y"})
    end

    it "keeps every = after the first" do
      Donico::Dotenv.parse("A=a=b=c\n").should eq({"A" => "a=b=c"})
    end

    it "reads an empty value" do
      Donico::Dotenv.parse("A=\n").should eq({"A" => ""})
    end

    it "ignores comments and blank lines" do
      Donico::Dotenv.parse("# comment\n\n   \nA=1\n  # indented\n").should eq({"A" => "1"})
    end

    it "drops a trailing comment introduced by whitespace" do
      Donico::Dotenv.parse("A=1 # tail\n").should eq({"A" => "1"})
    end

    it "keeps a # that is not preceded by whitespace" do
      Donico::Dotenv.parse("A=a#b\n").should eq({"A" => "a#b"})
    end

    it "keeps a # inside quotes" do
      Donico::Dotenv.parse(%(A="x # y"\n)).should eq({"A" => "x # y"})
    end

    it "does not interpolate variables" do
      Donico::Dotenv.parse("A=${B}\n").should eq({"A" => "${B}"})
    end

    it "does not substitute commands" do
      Donico::Dotenv.parse("A=$(id)\n").should eq({"A" => "$(id)"})
    end

    it "strips CRLF line endings" do
      Donico::Dotenv.parse("A=1\r\nB=\"x y\"\r\n\r\n# c\r\n").should eq({"A" => "1", "B" => "x y"})
    end

    it "lets a later line win over an earlier one" do
      Donico::Dotenv.parse("A=1\nA=2\n").should eq({"A" => "2"})
    end

    it "gives an empty value when a comment follows the = after whitespace" do
      Donico::Dotenv.parse("A= # c\nB=  #c\n").should eq({"A" => "", "B" => ""})
    end

    it "ignores a UTF-8 byte order mark at the start of the file" do
      Donico::Dotenv.parse("\uFEFFA=1\n").should eq({"A" => "1"})
    end

    it "rejects invalid UTF-8, naming the line number only" do
      text = String.new(Bytes[65, 61, 49, 10, 65, 61, 0xff, 0xfe, 10])
      error = expect_raises(Donico::ConfigError) { Donico::Dotenv.parse(text) }
      error.message.should eq(".env: line 2 is not KEY=VALUE")
    end

    it "ignores the spaces around the = and before the value" do
      Donico::Dotenv.parse("A = 1\nB =\"x y\"\nC=   z\n").should eq({"A" => "1", "B" => "x y", "C" => "z"})
    end

    it "keeps an empty quoted value, and a quote of the other kind inside quotes" do
      Donico::Dotenv.parse(%(A=""\nB='say "hi"'\nC="it's"\n)).should eq({"A" => "", "B" => %(say "hi"), "C" => "it's"})
    end

    it "accepts a comment after a closing quote" do
      Donico::Dotenv.parse(%(A="x" # c\n)).should eq({"A" => "x"})
    end

    it "rejects text after a closing quote" do
      error = expect_raises(Donico::ConfigError) { Donico::Dotenv.parse(%(A=1\nB="x" y\n)) }
      error.message.should eq(".env: line 2 is not KEY=VALUE")
    end

    it "rejects a name that is not an identifier" do
      {"1A=x", "A-B=1", "A B=1", "=1"}.each do |line|
        error = expect_raises(Donico::ConfigError) { Donico::Dotenv.parse("OK=1\n#{line}\n") }
        error.message.should eq(".env: line 2 is not KEY=VALUE")
      end
    end

    it "rejects a line that is not an assignment, naming its number only" do
      error = expect_raises(Donico::ConfigError) { Donico::Dotenv.parse("A=1\n# c\njust words\n") }
      error.message.should eq(".env: line 3 is not KEY=VALUE")
    end

    it "rejects an unterminated quote, naming its number only" do
      error = expect_raises(Donico::ConfigError) { Donico::Dotenv.parse(%(A=1\nA="open\n)) }
      error.message.should eq(".env: line 2 has an unterminated quote")
    end
  end

  it "refuses a NUL character, which no environment variable can hold" do
    error = expect_raises(Donico::ConfigError) { Donico::Dotenv.parse("A=1\nB=x\0y\n") }
    error.message.should eq ".env: line 2 holds a NUL character"
  end

  describe ".load" do
    it "returns a copy of vars when there is no .env" do
      with_tmp_dir do |dir|
        vars = {"A" => "1"}
        loaded = Donico::Dotenv.load(dir, vars)

        loaded.should eq({"A" => "1"})
        loaded.should_not be(vars)
      end
    end

    it "adds the variables of the .env" do
      with_tmp_dir do |dir|
        File.write(File.join(dir, ".env"), "B=2\n")

        Donico::Dotenv.load(dir, {"A" => "1"}).should eq({"A" => "1", "B" => "2"})
      end
    end

    it "keeps the value already in vars" do
      with_tmp_dir do |dir|
        File.write(File.join(dir, ".env"), "A=from-file\nB=2\n")

        Donico::Dotenv.load(dir, {"A" => "from-env"}).should eq({"A" => "from-env", "B" => "2"})
      end
    end

    it "reports an unreadable .env as a ConfigError" do
      pending!("root reads any file") if LibC.getuid == 0
      with_tmp_dir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "A=1\n")
        File.chmod(path, 0o000)
        begin
          error = expect_raises(Donico::ConfigError) { Donico::Dotenv.load(dir, {} of String => String) }
          error.message.should eq(".env: cannot be read")
        ensure
          File.chmod(path, 0o600)
        end
      end
    end
  end
end
