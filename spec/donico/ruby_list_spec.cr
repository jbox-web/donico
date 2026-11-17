require "../spec_helper"

# Every expected value is what Ruby's Array#inspect prints for the same
# strings, checked with `ruby` from the gem checkout.
describe Donico::RubyList do
  it "renders a plain list" do
    Donico::RubyList.render(["a", "b"]).should eq %(["a", "b"])
  end

  it "renders an empty list" do
    Donico::RubyList.render([] of String).should eq "[]"
  end

  it "escapes a double quote" do
    Donico::RubyList.render(["say \"hi\""]).should eq %(["say \\"hi\\""])
  end

  it "escapes a backslash" do
    Donico::RubyList.render(["back\\slash"]).should eq %(["back\\\\slash"])
  end

  it "writes a tab as \\t" do
    Donico::RubyList.render(["tab\there"]).should eq %(["tab\\there"])
  end

  it "writes a newline as \\n" do
    Donico::RubyList.render(["line\nbreak"]).should eq %(["line\\nbreak"])
  end

  it "writes the other short escapes Ruby has" do
    Donico::RubyList.render(["\e", "\a", "\b", "\f", "\v"]).should eq %q(["\e", "\a", "\b", "\f", "\v"])
  end

  it "writes a C1 control and a line separator as \\uXXXX" do
    Donico::RubyList.render(["\u0085", "\u2028", "a\u0080b"]).should eq %q(["\u0085", "\u2028", "a\u0080b"])
  end

  it "writes DEL as \\u007F" do
    Donico::RubyList.render(["del\u007Fchar"]).should eq %(["del\\u007Fchar"])
  end

  it "escapes the hash before a dollar sign" do
    Donico::RubyList.render(["dollar\#$x"]).should eq %(["dollar\\\#$x"])
  end

  it "escapes the hash before an at sign" do
    Donico::RubyList.render(["at\#@x"]).should eq %(["at\\\#@x"])
  end
end
