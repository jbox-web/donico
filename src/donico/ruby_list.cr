module Donico
  module RubyList
    # A list of strings the way Ruby's Array#inspect writes it: what the gem
    # interpolated into the committed docker-bake.hcl files, and what its task
    # descriptions show.
    def self.render(items : Array(String)) : String
      "[#{items.join(", ") { |item| ruby_inspect(item) }}]"
    end

    # What String#inspect writes for the characters with a short escape.
    INSPECT_ESCAPES = {
      '"' => "\\\"", '\\' => "\\\\", '\n' => "\\n", '\r' => "\\r", '\t' => "\\t",
      '\e' => "\\e", '\a' => "\\a", '\b' => "\\b", '\f' => "\\f", '\v' => "\\v",
    }

    # String#inspect for the characters a platform name can plausibly hold:
    # the quote and the backslash, `#` before `{`, `$` or `@`, and the
    # control characters.
    private def self.ruby_inspect(value : String) : String
      String.build do |io|
        io << '"'
        chars = value.chars
        chars.each_with_index do |char, index|
          if escape = INSPECT_ESCAPES[char]?
            io << escape
          elsif char == '#' && chars[index + 1]?.in?('{', '$', '@')
            io << "\\#"
          elsif non_printable?(char)
            # Ruby writes the other non-printable characters of a UTF-8
            # string as \uXXXX.
            io << "\\u" << char.ord.to_s(16, upcase: true).rjust(4, '0')
          else
            io << char
          end
        end
        io << '"'
      end
    end

    private def self.non_printable?(char : Char) : Bool
      char.ord < 0x20 || (0x7F..0x9F).includes?(char.ord) || {0x2028, 0x2029}.includes?(char.ord)
    end
  end
end
