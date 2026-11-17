require "./config"
require "./error"

module Donico
  # Writer of .gitlab-ci/extends/.matrix.yml. The file is committed in every
  # image repository and must not change when the repository moves from the
  # Ruby gem to this binary, so it is written by hand to reproduce, byte for
  # byte, what Psych 5.3.1 emits for the same data: a stdlib YAML emitter
  # would pick other quoting rules.
  module MatrixFile
    HEADER = "# !!! THIS IS A GENERATED FILE !!! DON'T EDIT ME MANUALLY !!!\n" \
             "# Instead edit #{Config::FILE} and run donico generate-files\n---\n"

    VERSION_KEY = "    - VERSION: "
    DISTRO_KEY  = "      DOCKER_DISTRO: "

    # Ruby's [[:word:]]: letter, mark, decimal digit or connector punctuation.
    private WORD_FIRST = /\A[^\p{L}\p{M}\p{Nd}\p{Pc}][^"]*\z/

    # What Psych's ScalarScanner reads as a string at its first branch: an
    # optional leading character, then letters, underscore, whitespace or
    # one of these punctuation marks. (Ruby `\s` is ASCII-only.)
    private STRING_START = /\A[^\d.:\-]?[\p{L}_ \t\r\n\f\v!@#$%\^&*(){}<>|\/\\~;=]+/

    private TIME              = /\A-?\d{4}-\d{1,2}-\d{1,2}(?:[Tt]|\s+)\d{1,2}:\d\d:\d\d(?:\.\d*)?(?:\s*(?:Z|[-+]\d{1,2}:?(?:\d\d)?))?\z/
    private DATE              = /\A(\d{4})-(1[012]|0\d|\d)-([12]\d|3[01]|0\d|\d)\z/
    private SEXAGESIMAL       = /\A[-+]?[0-9][0-9_]*(:[0-5]?[0-9]){1,2}\z/
    private SEXAGESIMAL_FLOAT = /\A[-+]?[0-9][0-9_]*(:[0-5]?[0-9]){1,2}\.[0-9_]*\z/
    private FLOAT             = /\A(?:[-+]?([0-9][0-9_,]*)?\.[0-9]*([eE][-+][0-9]+)?)\z/
    # Psych's legacy integer pattern, the one used unless `strict_integer`.
    private INTEGER = /\A(?:[-+]?0b[_,]*[0-1][0-1_,]*|[-+]?0[_,]*[0-7][0-7_,]*|[-+]?(?:0|[1-9](?:[0-9]|,[0-9]|_[0-9])*)|[-+]?0x[_,]*[0-9a-fA-F][0-9a-fA-F_,]*)\z/

    # The whole file for `config`. Fails, naming the row and the key, on a
    # value `scalar` cannot write.
    def self.render(config : Config) : String
      String.build do |io|
        io << HEADER << "\".matrix\":\n  parallel:\n"
        if config.matrix.empty?
          io << "    matrix: []\n"
        else
          io << "    matrix:\n"
          config.matrix.each_with_index do |entry, index|
            io << VERSION_KEY << scalar(entry.version, "matrix[#{index}].version", VERSION_KEY.size) << '\n'
            io << DISTRO_KEY << scalar(entry.distro, "matrix[#{index}].distro", DISTRO_KEY.size) << '\n'
          end
        end
      end
    end

    # `value` as Psych writes a String in a block mapping. `subject` names the
    # value in the error message; `column` is the width of what precedes the
    # value on its line. The six steps, in Psych's order:
    #
    # 1. what is not worth reproducing (block and tagged forms, a line libyaml
    #    would fold) is refused;
    # 2. `y`, `Y`, `n`, `N` are double-quoted (YAML 1.1 booleans);
    # 3. a first character that is not a word character, without a `"` after
    #    it, gives double quotes;
    # 4. a value the scalar scanner would read as another type, or an octal
    #    with a 8 or 9 digit, gives single quotes;
    # 5. the plain style libyaml refuses (empty, space at either end, `: `,
    #    ` #`, trailing `:`) gives single quotes;
    # 6. everything else is bare.
    def self.scalar(value : String, subject : String = "value", column : Int32 = 0) : String
      reason = unwritable(value)
      raise ConfigError.new("#{Config::FILE}: #{subject} cannot be written to the CI matrix file: #{reason}") if reason

      written = styled(value)
      if folded?(written, column)
        raise ConfigError.new("#{Config::FILE}: #{subject} cannot be written to the CI matrix file: it holds a space past column 80, where YAML would fold the line")
      end
      written
    end

    private def self.styled(value : String) : String
      if astral?(value)
        # libyaml does not count characters beyond the BMP as printable: it
        # escapes them, which only the double-quoted style can do.
        double_quoted(value)
      elsif {"y", "Y", "n", "N"}.includes?(value)
        double_quoted(value)
      elsif value.matches?(WORD_FIRST)
        double_quoted(value)
      elsif !string_for_scanner?(value) || value.matches?(/\A0[0-7]*[89]/)
        single_quoted(value)
      elsif plain_refused?(value)
        single_quoted(value)
      else
        value
      end
    end

    private def self.unwritable(value : String) : String?
      return "it is the YAML merge key" if value == "<<"
      value.each_char do |char|
        return "it contains a line break" if {'\n', '\r', '\u0085', '\u2028', '\u2029'}.includes?(char)
      end
      value.each_char do |char|
        return "it contains a control character" unless printable?(char)
      end
      nil
    end

    # libyaml folds a line at a space once the column before it passes 80.
    # `written` is the styled value, quotes included, so they count. Such a
    # value would be written over several lines, which `scalar` does not
    # reproduce. Measured on Psych 5.3.1 for the three styles.
    private def self.folded?(written : String, column : Int32) : Bool
      written.each_char_with_index do |char, index|
        next unless char == ' ' && index > 0 && written[index - 1] != ' '
        return true if column + index > 80
      end
      false
    end

    private def self.astral?(value : String) : Bool
      value.each_char.any? { |char| char.ord >= 0x10000 }
    end

    # libyaml's notion of a printable character.
    private def self.printable?(char : Char) : Bool
      code = char.ord
      (0x20..0x7E).includes?(code) || (0xA0..0xD7FF).includes?(code) ||
        ((0xE000..0xFFFD).includes?(code) && code != 0xFEFF) || code >= 0x10000
    end

    private def self.plain_refused?(value : String) : Bool
      value.empty? || value.starts_with?(' ') || value.ends_with?(' ') ||
        value.includes?(": ") || value.includes?(" #") || value.ends_with?(':') ||
        starts_with_indicator?(value)
    end

    # libyaml refuses the plain style for a value that opens with a YAML
    # indicator. Step 3 already caught every non-word first character
    # unless the rest holds a `"`, so this only decides those values.
    private def self.starts_with_indicator?(value : String) : Bool
      first = value[0]
      return true if "#,[]{}&*!|>'\"%@`".includes?(first)
      return true if value.starts_with?("---") || value.starts_with?("...")
      "?:-".includes?(first) && (value.size == 1 || value[1].ascii_whitespace?)
    end

    private def self.single_quoted(value : String) : String
      "'#{value.gsub("'", "''")}'"
    end

    private def self.double_quoted(value : String) : String
      escaped = String.build do |io|
        value.each_char do |char|
          case char
          when '\\' then io << "\\\\"
          when '"'  then io << "\\\""
          else
            if char.ord >= 0x10000
              io << "\\U" << char.ord.to_s(16, upcase: true).rjust(8, '0')
            else
              io << char
            end
          end
        end
      end
      "\"#{escaped}\""
    end

    # Port of Psych::ScalarScanner#tokenize, reduced to its one useful answer:
    # does the scanner leave this value a String? Everything it turns into
    # another type (nil, booleans, numbers, dates, times, symbols) reads back
    # differently, so the writer quotes it.
    private def self.string_for_scanner?(value : String) : Bool
      return false if value.empty?
      return !keyword?(value) if value.matches?(STRING_START)
      return !time?(value) if value.matches?(TIME)
      date = DATE.match(value)
      return !valid_date?(date[1].to_i, date[2].to_i, date[3].to_i) if date
      !numeric?(value)
    end

    # The first branch of the scanner: short words that mean nil or a boolean.
    private def self.keyword?(value : String) : Bool
      value.size <= 5 && value.downcase.in?("~", "null", "yes", "true", "on", "no", "false", "off")
    end

    # The remaining branches: infinity, NaN, symbols, sexagesimal numbers,
    # floats and integers.
    private def self.numeric?(value : String) : Bool
      return true if value.matches?(/\A[-+]?\.inf\z/i) || value.matches?(/\A\.nan\z/i)
      return true if value.matches?(/\A:./)
      return true if value.matches?(SEXAGESIMAL) || value.matches?(SEXAGESIMAL_FLOAT)
      return !value.matches?(/\A[-+]?\.\z/) if value.matches?(FLOAT)
      value.matches?(INTEGER)
    end

    private def self.valid_date?(year : Int32, month : Int32, day : Int32) : Bool
      return false unless 1 <= month <= 12 && day >= 1
      leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
      days = {31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
      day <= days[month - 1]
    end

    # Whether Psych's parse_time accepts a value the TIME pattern matched:
    # Ruby's Time.utc and Time.new reject out-of-range fields, and Psych then
    # falls back to the string.
    private def self.time?(value : String) : Bool
      date, _, rest = value.partition(/[ tT]/)
      day = date.match(/\A(-?\d{4})-(\d{1,2})-(\d{1,2})/)
      clock = rest.match(/(\d+):(\d+):(\d+)(?:\.(\d*))?\s*(Z|[-+]\d+(?::\d\d)?)?/)
      return false unless day && clock
      return false unless 1 <= day[2].to_i <= 12 && 1 <= day[3].to_i <= 31
      return false unless clock_valid?(clock[1].to_i, clock[2].to_i, clock[3].to_i)
      zone = clock[5]?
      zone.nil? || zone == "Z" || zone_valid?(zone)
    end

    private def self.clock_valid?(hour : Int32, minute : Int32, second : Int32) : Bool
      return false unless 0 <= hour <= 24 && 0 <= minute <= 59 && 0 <= second <= 60
      hour < 24 || (minute == 0 && second == 0)
    end

    # Time.new takes an offset of less than a day, in either direction.
    private def self.zone_valid?(zone : String) : Bool
      parts = zone.match(/\A([+\-]?\d{1,2}):?(\d{1,2})?\z/)
      return false unless parts
      hours = parts[1].to_i * 3600
      minutes = (parts[2]?.try(&.to_i) || 0) * 60
      (hours < 0 ? hours - minutes : hours + minutes).abs < 86400
    end
  end
end
