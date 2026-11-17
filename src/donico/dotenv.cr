require "./error"

module Donico
  # Parser of the project's `.env`. The syntax is deliberately plain: the
  # binary never evaluates anything found in that file, so there is no
  # interpolation, no command substitution and no escape processing. Errors
  # name the line number and never the line itself, since the content may be a
  # secret.
  module Dotenv
    KEY = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    def self.parse(text : String) : Hash(String, String)
      vars = {} of String => String
      # A byte order mark written by some editors is not part of the first key.
      text.lchop('\uFEFF').each_line.with_index(1) do |raw, number|
        # Checked before any regex or strip touches the line, which would raise.
        raise ConfigError.new(".env: line #{number} is not KEY=VALUE") unless raw.valid_encoding?
        # No environment variable can hold one: the spawn of the first child
        # would fail on it, far from the line that wrote it.
        raise ConfigError.new(".env: line #{number} holds a NUL character") if raw.includes?('\0')
        # each_line removes "\n" only; a CRLF file leaves the "\r" behind.
        line = raw.strip
        next if line.empty? || line.starts_with?('#')
        line = line.lchop("export ").lstrip if line.starts_with?("export ")

        key, separator, value = line.partition('=')
        key = key.rstrip
        raise ConfigError.new(".env: line #{number} is not KEY=VALUE") if separator.empty? || !KEY.matches?(key)

        vars[key] = parse_value(value.lstrip, number)
      end
      vars
    end

    # Returns `vars` completed by the `.env` of `dir`, when there is one. A key
    # already in `vars` keeps its value: the process environment wins.
    def self.load(dir : String, vars : Hash(String, String)) : Hash(String, String)
      path = File.join(dir, ".env")
      return vars.dup unless File.file?(path)
      content = begin
        File.read(path)
      rescue File::Error
        raise ConfigError.new(".env: cannot be read")
      end
      parse(content).merge(vars)
    end

    private def self.parse_value(value : String, number : Int32) : String
      quote = value[0]?
      return unquoted(value) unless quote && (quote == '"' || quote == '\'')

      closing = value.index(quote, 1)
      raise ConfigError.new(".env: line #{number} has an unterminated quote") unless closing

      rest = value[(closing + 1)..].lstrip
      unless rest.empty? || rest.starts_with?('#')
        raise ConfigError.new(".env: line #{number} is not KEY=VALUE")
      end
      value[1...closing]
    end

    # A `#` starts a comment at the very start of the value or after
    # whitespace, so `a#b` stays whole.
    private def self.unquoted(value : String) : String
      return "" if value.starts_with?('#')
      value.sub(/\s+#.*\z/, "").rstrip
    end
  end
end
