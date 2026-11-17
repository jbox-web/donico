require "../spec_helper"

describe Donico::Hcl do
  describe ".escape" do
    it "escapes a double quote" do
      Donico::Hcl.escape(%(say "hi")).should eq %(say \\"hi\\")
    end

    it "doubles a backslash" do
      Donico::Hcl.escape(%(C:\\tmp)).should eq %(C:\\\\tmp)
    end

    it "doubles the backslash before escaping the quote, never the one it adds" do
      # Input: a\"  (backslash, quote). Expected: a\\\"  (two backslashes for
      # the backslash, then one backslash and the quote).
      Donico::Hcl.escape(%(a\\")).should eq %(a\\\\\\")
    end

    it "leaves a dollar sign alone, so ${HOME} stays an HCL reference" do
      Donico::Hcl.escape("${HOME}/.aws/credentials").should eq "${HOME}/.aws/credentials"
    end

    it "leaves a plain value untouched" do
      Donico::Hcl.escape("trixie").should eq "trixie"
    end
  end

  # In an HCL string `${` opens an interpolation and `%{` a directive; doubling
  # the first character writes them literally. Measured with a real build:
  # `"x $${HOME} 100%%{y}"` reaches the Dockerfile as `x ${HOME} 100%{y}`.
  describe ".literal" do
    it "doubles the first character of an interpolation and of a directive" do
      Donico::Hcl.literal("a ${B} 100%{c}").should eq "a $${B} 100%%{c}"
    end

    it "escapes quotes and backslashes like .escape" do
      Donico::Hcl.literal(%q(say "hi" C:\\tmp)).should eq %q(say \"hi\" C:\\\\tmp)
    end

    it "leaves a lone dollar or percent sign alone" do
      Donico::Hcl.literal("5$ 10% $HOME").should eq "5$ 10% $HOME"
    end
  end
end
