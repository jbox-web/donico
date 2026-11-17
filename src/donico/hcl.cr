module Donico
  # Escaping for values interpolated into the generated docker-bake.hcl.
  module Hcl
    # Escapes a value for insertion inside a quoted HCL string. The backslash
    # goes first: escaping the quote first would have the backslash it adds
    # doubled right after.
    #
    # `$` is deliberately left alone: `${...}` inside a bake value is an HCL
    # variable reference, used by donico.yml files for secret sources such as
    # "${HOME}/.aws/credentials". Escaping it would break that usage.
    def self.escape(value : String) : String
      value.gsub("\\", "\\\\").gsub("\"", "\\\"")
    end

    # Escapes a value that is plain text, never an HCL template: on top of
    # `escape`, `${` and `%{` are written `$${` and `%%{`, which bake reads
    # back as the two characters themselves. Used for everything but a secret
    # source: a build arg such as `PS1=${debian_chroot}` is meant for the
    # Dockerfile, and left as is it made bake look for a variable of that name.
    def self.literal(value : String) : String
      escape(value).gsub("${", "$${").gsub("%{", "%%{")
    end
  end
end
