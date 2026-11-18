require "crest"
require "json"
require "../../error"

# OpenSSL's built-in default certificate file (OPENSSLDIR/cert.pem), which
# the stdlib of Crystal 1.20.3 does not bind.
lib LibCrypto
  fun x509_get_default_cert_file = X509_get_default_cert_file : LibC::Char*
end

module Donico
  module Fleet
    module Versions
      # Resolves an upstream repository's version from the GitHub API. Only the
      # three lookups the version check needs: latest release, latest tag, and
      # latest tag inside a minor series.
      #
      # `transport` is the seam: a callable (path -> {status, parsed body}). It
      # defaults to a real HTTPS GET through crest; specs inject a fake, or point
      # `base` at a local server. The token is never logged, never put in a
      # message and never sent anywhere but in the Authorization header of the
      # default transport.
      #
      # A rate limit raises `RateLimited` rather than returning nil: reporting a
      # throttled lookup as "no version found" would silently produce wrong
      # tables.
      class Github
        # A 403 or 429 whose body says "rate limit".
        class RateLimited < Error
        end

        # Any other status GitHub answers that is neither 200 nor 404, and a
        # request that got no answer at all.
        class RequestError < Error
        end

        API             = "https://api.github.com"
        CONNECT_TIMEOUT = 5.seconds
        READ_TIMEOUT    = 10.seconds

        # Tag paging. The ceiling is a quota guard, not a correctness one: a
        # constrained series older than 1000 tags would need a different lookup
        # altogether, and burning that many requests on one image would throttle
        # the scan of the whole fleet.
        PER_PAGE  = 100
        MAX_PAGES =  10

        # Normalises a tag to the form used in donico.yml: drop any non-digit
        # prefix ("v3.7.9" -> "3.7.9") and rewrite Debian-style security tags
        # ("1.26.3+security-01" -> "1.26.3-01").
        def self.strip_prefix(tag : String?) : String?
          return if tag.nil?

          tag.sub(/\A[^0-9]*/, "").sub("+security-", "-")
        end

        # The system bundle every macOS ships.
        DARWIN_BUNDLE = "/etc/ssl/cert.pem"

        # `vars` are the fleet's variables (the process environment completed by
        # the configuration repository's .env): SSL_CERT_FILE and SSL_CERT_DIR
        # are read there, never in the global ENV.
        def initialize(@token : String?, @transport : (String -> {Int32, JSON::Any?})? = nil, @base : String = API,
                       @vars : Hash(String, String) = {} of String => String)
        end

        # The CA file and directory to load on top of OpenSSL's defaults, nil
        # each when the defaults stand.
        #
        # Why: the release binaries link OpenSSL statically, and its default
        # locations are those of the machine that built it, compiled in. On
        # Linux they are the distribution's (/etc/ssl). On darwin they are the
        # build runner's Homebrew prefix (/opt/homebrew/etc/openssl@4, or
        # /usr/local/... on Intel): on a Mac without that formula there are no
        # certificates at all, so the system bundle is used instead.
        # SSL_CERT_FILE and SSL_CERT_DIR are applied explicitly because OpenSSL
        # only reads them from the process environment, and the fleet's may
        # come from a .env. `exists` is File.file? outside the specs.
        def self.ca_locations(vars : Hash(String, String), darwin : Bool, default_file : String,
                              exists : String -> Bool) : {String?, String?}
          file = vars["SSL_CERT_FILE"]?.presence
          dir = vars["SSL_CERT_DIR"]?.presence
          return {file, dir} if file || dir
          return {DARWIN_BUNDLE, nil} if darwin && !exists.call(default_file) && exists.call(DARWIN_BUNDLE)

          {nil, nil}
        end

        # The upstream version, normalised, or nil when nothing resolves. Prefers
        # the published release; falls back to the tag list. A `constraint`
        # ("3.6") restricts the answer to that minor series.
        def resolve(repo : String, constraint : String? = nil) : String?
          tag = constraint ? latest_tag_in_minor(repo, constraint) : (latest_release(repo) || latest_tag(repo))
          self.class.strip_prefix(tag)
        end

        private def latest_release(repo : String) : String?
          value = fetch("repos/#{repo}/releases/latest").try(&.as_h?).try(&.["tag_name"]?).try(&.as_s?)
          value.nil? || value.empty? ? nil : value
        end

        private def latest_tag(repo : String) : String?
          fetch("repos/#{repo}/tags?per_page=1").try(&.as_a?).try(&.first?).try(&.as_h?).try(&.["name"]?).try(&.as_s?)
        end

        # The greatest tag of the "<minor>." series, with or without a leading v.
        # Matching on the trailing dot keeps "3.6" from picking up "3.60.1".
        #
        # Greatest, not first: the API promises no order, and taking whichever
        # matched first made the answer depend on the page's arrangement. Compared
        # segment by segment, so 3.6.10 beats 3.6.9 where a string comparison has
        # it the other way round.
        private def latest_tag_in_minor(repo : String, minor : String) : String?
          names = tag_names(repo).select { |name| name.starts_with?("#{minor}.") || name.starts_with?("v#{minor}.") }
          names.max_by? { |name| segments(name) }
        end

        # The numeric segments of a tag, as Ruby's `to_i` reads them: the leading
        # digits of each, 0 when there are none.
        private def segments(name : String) : Array(Int64)
          self.class.strip_prefix(name).to_s.split(/[.-]/).map { |part| part[/\A\d+/]?.try(&.to_i64?) || 0_i64 }
        end

        # Every tag of `repo`, page by page. Stops on the first short or empty
        # page, which is the end of the list, and on MAX_PAGES.
        private def tag_names(repo : String) : Array(String)
          names = [] of String
          (1..MAX_PAGES).each do |page|
            tags = fetch("repos/#{repo}/tags?per_page=#{PER_PAGE}&page=#{page}").try(&.as_a?)
            break if tags.nil? || tags.empty?

            tags.each { |tag| tag.as_h?.try(&.["name"]?).try(&.as_s?).try { |name| names << name } }
            break if tags.size < PER_PAGE
          end
          names
        end

        # The parsed body on a 200 (nil when it is not JSON), nil on a 404 (no
        # release, unknown path), and an error on anything else so a throttled
        # or broken lookup is never mistaken for a missing version.
        private def fetch(path : String) : JSON::Any?
          status, body = transport.call(path)
          return body if status == 200
          return if status == 404

          raise RateLimited.new(rate_limit_message(body)) if rate_limited?(status, body)

          raise RequestError.new("GitHub #{status}: #{message_of(body)}")
        end

        # 403 is GitHub's primary-limit status, 429 the secondary one; both carry
        # the reason in the body message.
        private def rate_limited?(status : Int32, body : JSON::Any?) : Bool
          (status == 403 || status == 429) && message_of(body).matches?(/rate limit/i)
        end

        private def rate_limit_message(body : JSON::Any?) : String
          who = token? ? "with a token" : "without GITHUB_TOKEN (60 requests/hour)"
          "GitHub rate limit reached #{who}: #{message_of(body)}"
        end

        private def message_of(body : JSON::Any?) : String
          body.try(&.as_h?).try(&.["message"]?).try(&.as_s?).to_s
        end

        private def token? : Bool
          !@token.to_s.empty?
        end

        private def transport : String -> {Int32, JSON::Any?}
          @transport || ->(path : String) { get(path) }
        end

        # Default transport: a GET on `<base>/<path>`, JSON in and out. crest
        # would raise on a 4xx and follow ten redirects; here every status is
        # data (`handle_errors: false`) and none is followed (`max_redirects:
        # 0`, as the gem). An answer that is not JSON gives a nil body.
        private def get(path : String) : {Int32, JSON::Any?}
          headers = {"Accept" => "application/vnd.github+json"}
          headers["Authorization"] = "Bearer #{@token}" if token?

          response = Crest.get(
            "#{@base}/#{path}",
            headers: headers,
            connect_timeout: CONNECT_TIMEOUT,
            read_timeout: READ_TIMEOUT,
            handle_errors: false,
            max_redirects: 0,
            tls: tls_context,
          )
          {response.status_code, parse(response.body)}
        rescue e : IO::Error | OpenSSL::Error
          raise RequestError.new("GitHub request failed: #{e.message}")
        end

        # The client context of an https base: OpenSSL's defaults, plus what
        # `ca_locations` adds. A plain http base (the specs' local server) has
        # none. A location that cannot be loaded fails the request, naming it.
        private def tls_context : OpenSSL::SSL::Context::Client?
          return unless @base.starts_with?("https:")

          context = OpenSSL::SSL::Context::Client.new
          default_file = String.new(LibCrypto.x509_get_default_cert_file)
          file, dir = self.class.ca_locations(@vars, {{ flag?(:darwin) }}, default_file, ->(path : String) { File.file?(path) })
          file.try { |path| load_ca(path) { context.ca_certificates = path } }
          dir.try { |path| load_ca(path) { context.ca_certificates_path = path } }
          context
        end

        # OpenSSL's own message does not name the file it could not read.
        private def load_ca(path : String, &) : Nil
          yield
        rescue e : OpenSSL::Error
          raise RequestError.new("GitHub request failed: cannot load CA certificates from #{path}: #{e.message}")
        end

        private def parse(body : String) : JSON::Any?
          JSON.parse(body)
        rescue JSON::ParseException
          nil
        end
      end
    end
  end
end
