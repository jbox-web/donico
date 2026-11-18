require "../../../spec_helper"
require "http"
require "socket"

private alias Reply = {Int32, JSON::Any?}

private def json(text : String) : JSON::Any
  JSON.parse(text)
end

private def tags_json(names : Array(String)) : JSON::Any
  JSON.parse(names.map { |name| {"name" => name} }.to_json)
end

# A client on a fake transport: the routes map a request path to the
# status and parsed body the real transport would return; anything else is a 404.
private def client(routes : Hash(String, Reply), token : String? = nil, seen : Array(String)? = nil) : Donico::Fleet::Versions::Github
  transport = ->(path : String) : Reply do
    seen.try(&.<< path)
    routes.fetch(path) { {404, json(%({"message":"Not Found"}))} }
  end
  Donico::Fleet::Versions::Github.new(token, transport)
end

private def release(tag : String) : Reply
  {200, json(%({"tag_name":"#{tag}"}))}
end

private def message(status : Int32, text : String) : Reply
  {status, json(%({"message":"#{text}"}))}
end

private TAGS_PAGE_1 = "repos/some/repo/tags?per_page=100&page=1"

# What the server saw of one request: its resource and its headers.
private alias Seen = {String, HTTP::Headers}

# The default transport, against a minimal server on 127.0.0.1 (port chosen by
# the system), bound before the fiber starts. It serves `connections`
# connections one after the other (a lookup that falls back from the release to
# the tag list makes two), each with the canned `status` and `body` written as
# literal bytes, `Connection: close`. What it saw of each request crosses to
# the spec through `requests`, a buffered Channel, never a shared array.
#
# No HTTP::Server, on purpose: it spawns one fiber per connection on any worker
# thread, and under -Dpreview_mt every thread has its own event loop, so the
# accepted socket would not live on the loop of the listener and of the client
# (a spinning hang was measured). Here the one fiber is pinned to the spec
# fiber's thread (`same_thread: true`), so every socket of the example is driven
# by one event loop. The pin is asked under -Dpreview_mt only: without the flag
# there is one thread anyway, and a compiler whose scheduler is the execution
# contexts (the nightly, which has dropped the flag) refuses `same_thread: true`
# with a RuntimeError. The lifecycle is deterministic: the fiber signals `done`
# when it returns, and the helper waits for it after closing the listener,
# bounded so that a failure is an example failure and never a hang.
private def with_server(status : Int32, body : String, connections : Int32 = 1, & : String, Channel(Seen) ->) : Nil
  requests = Channel(Seen).new(16)
  done = Channel(Nil).new
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  serve = -> do
    connections.times do
      socket = server.accept? || break
      begin
        socket.read_timeout = 5.seconds
        requests.send(read_request_head(socket))
        socket.write "HTTP/1.1 #{status} #{HTTP::Status.new(status).description}\r\n".to_slice
        socket.write "Content-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n".to_slice
        socket.write body.to_slice
      rescue IO::Error
      ensure
        socket.close
      end
    end
rescue IO::Error
ensure
  done.send(nil)
  end
  {% if flag?(:preview_mt) %}
    spawn(same_thread: true) { serve.call }
  {% else %}
    spawn { serve.call }
  {% end %}
  begin
    yield "http://127.0.0.1:#{port}", requests
  ensure
    server.close
    select
    when done.receive
    when timeout(5.seconds)
      fail "the server did not stop within 5 seconds"
    end
  end
end

# The request line and headers, up to the blank line: the resource and the
# headers.
private def read_request_head(socket : IO) : Seen
  resource = socket.gets.to_s.split(' ')[1]? || ""
  headers = HTTP::Headers.new
  while (line = socket.gets) && !line.strip.empty?
    name, _, value = line.partition(':')
    headers[name.strip] = value.strip
  end
  {resource, headers}
end

# The next request the server saw, bounded.
private def seen_request(requests : Channel(Seen)) : Seen
  select
  when seen = requests.receive
    seen
  when timeout(5.seconds)
    fail "the server saw no request within 5 seconds"
  end
end

private def http_client(base : String, token : String? = nil) : Donico::Fleet::Versions::Github
  Donico::Fleet::Versions::Github.new(token, nil, base)
end

describe Donico::Fleet::Versions::Github do
  describe ".strip_prefix" do
    it "drops any non-digit prefix" do
      Donico::Fleet::Versions::Github.strip_prefix("v3.7.9").should eq "3.7.9"
      Donico::Fleet::Versions::Github.strip_prefix("release-2.1").should eq "2.1"
      Donico::Fleet::Versions::Github.strip_prefix("3.7.9").should eq "3.7.9"
    end

    it "normalises a +security- segment to a dash" do
      Donico::Fleet::Versions::Github.strip_prefix("1.26.3+security-01").should eq "1.26.3-01"
    end

    it "returns nil unchanged" do
      Donico::Fleet::Versions::Github.strip_prefix(nil).should be_nil
    end
  end

  describe "#resolve without a constraint" do
    it "returns the release tag, normalised" do
      client({"repos/traefik/traefik/releases/latest" => release("v3.7.9")}).resolve("traefik/traefik").should eq "3.7.9"
    end

    it "prefers the release over the tag list" do
      routes = {
        "repos/some/repo/releases/latest" => release("v2.0.0"),
        "repos/some/repo/tags?per_page=1" => {200, tags_json(["v9.9.9"])},
      }
      client(routes).resolve("some/repo").should eq "2.0.0"
    end

    it "falls back to the first tag when there is no release" do
      client({"repos/some/repo/tags?per_page=1" => {200, tags_json(["0.17"])}}).resolve("some/repo").should eq "0.17"
    end

    it "falls back to the tag list when the release has an empty tag" do
      routes = {
        "repos/some/repo/releases/latest" => release(""),
        "repos/some/repo/tags?per_page=1" => {200, tags_json(["0.17"])},
      }
      client(routes).resolve("some/repo").should eq "0.17"
    end

    it "returns nil when the repository has neither release nor tag" do
      client({"repos/some/repo/tags?per_page=1" => {200, json("[]")}}).resolve("some/repo").should be_nil
    end

    it "returns nil on a 404 for both lookups" do
      client({} of String => Reply).resolve("some/repo").should be_nil
    end

    # A 200 that is not JSON reaches the client as a nil body.
    it "returns nil when the release body is not JSON" do
      routes = {"repos/some/repo/releases/latest" => {200, nil.as(JSON::Any?)}}
      client(routes).resolve("some/repo").should be_nil
    end

    it "returns nil when the tag body is not JSON" do
      routes = {"repos/some/repo/tags?per_page=1" => {200, nil.as(JSON::Any?)}}
      client(routes).resolve("some/repo").should be_nil
    end

    it "returns nil when the release body has an unexpected shape" do
      routes = {
        "repos/some/repo/releases/latest" => {200, json(%(["x"]))},
        "repos/some/repo/tags?per_page=1" => {200, json(%({"name":"1.0"}))},
      }
      client(routes).resolve("some/repo").should be_nil
    end
  end

  describe "#resolve with a constraint" do
    it "returns the greatest tag of the series, with or without a v prefix" do
      routes = {TAGS_PAGE_1 => {200, tags_json(["3.7.0", "v3.6.13", "3.6.11"])}}
      client(routes).resolve("some/repo", "3.6").should eq "3.6.13"
    end

    it "does not match a longer minor sharing the prefix" do
      routes = {TAGS_PAGE_1 => {200, tags_json(["3.60.1"])}}
      client(routes).resolve("some/repo", "3.6").should be_nil
    end

    it "returns the greatest tag of the series, not the first one listed" do
      routes = {TAGS_PAGE_1 => {200, tags_json(["3.6.11", "3.6.13", "3.6.9"])}}
      client(routes).resolve("some/repo", "3.6").should eq "3.6.13"
    end

    it "compares segment by segment rather than as text" do
      routes = {TAGS_PAGE_1 => {200, tags_json(["v3.6.9", "v3.6.10"])}}
      client(routes).resolve("some/repo", "3.6").should eq "3.6.10"
    end

    it "does not look at the release when constrained" do
      seen = [] of String
      routes = {
        "repos/some/repo/releases/latest" => release("v4.0.0"),
        TAGS_PAGE_1                       => {200, tags_json(["3.6.13"])},
      }
      client(routes, seen: seen).resolve("some/repo", "3.6").should eq "3.6.13"
      seen.should eq [TAGS_PAGE_1]
    end

    it "walks the pages until a short page" do
      seen = [] of String
      routes = {
        TAGS_PAGE_1                                => {200, tags_json(Array.new(100) { |i| "4.0.#{i}" })},
        "repos/some/repo/tags?per_page=100&page=2" => {200, tags_json(["3.6.13"])},
        "repos/some/repo/tags?per_page=100&page=3" => {200, tags_json(["3.6.99"])},
      }
      client(routes, seen: seen).resolve("some/repo", "3.6").should eq "3.6.13"
      seen.should eq [TAGS_PAGE_1, "repos/some/repo/tags?per_page=100&page=2"]
    end

    it "stops at ten pages of full tags" do
      seen = [] of String
      transport = ->(path : String) : Reply do
        seen << path
        {200, tags_json(Array.new(100) { "4.0.0" })}
      end
      Donico::Fleet::Versions::Github.new(nil, transport).resolve("some/repo", "3.6").should be_nil
      seen.size.should eq 10
      seen.last.should eq "repos/some/repo/tags?per_page=100&page=10"
    end

    it "stops on an empty page" do
      seen = [] of String
      client({TAGS_PAGE_1 => {200, json("[]")}}, seen: seen).resolve("some/repo", "3.6").should be_nil
      seen.size.should eq 1
    end

    it "stops when a page is not JSON" do
      seen = [] of String
      client({TAGS_PAGE_1 => {200, nil.as(JSON::Any?)}}, seen: seen).resolve("some/repo", "3.6").should be_nil
      seen.size.should eq 1
    end
  end

  describe "failures" do
    it "raises RateLimited on a 403 whose message says rate limit, with a token" do
      routes = {"repos/some/repo/releases/latest" => message(403, "API rate limit exceeded for 1.2.3.4")}
      expect_raises(Donico::Fleet::Versions::Github::RateLimited, "GitHub rate limit reached with a token: API rate limit exceeded for 1.2.3.4") do
        client(routes, "sekret-token-value").resolve("some/repo")
      end
    end

    it "raises RateLimited without a token, naming the anonymous limit" do
      routes = {"repos/some/repo/releases/latest" => message(403, "API rate limit exceeded for 1.2.3.4")}
      expect_raises(Donico::Fleet::Versions::Github::RateLimited, "GitHub rate limit reached without GITHUB_TOKEN (60 requests/hour): API rate limit exceeded for 1.2.3.4") do
        client(routes).resolve("some/repo")
      end
    end

    it "treats an empty token as no token" do
      routes = {"repos/some/repo/releases/latest" => message(403, "API rate limit exceeded")}
      expect_raises(Donico::Fleet::Versions::Github::RateLimited, "without GITHUB_TOKEN (60 requests/hour)") do
        client(routes, "").resolve("some/repo")
      end
    end

    it "raises RateLimited on a secondary-limit 429 too" do
      routes = {"repos/some/repo/releases/latest" => message(429, "You have exceeded a secondary rate limit")}
      expect_raises(Donico::Fleet::Versions::Github::RateLimited, "GitHub rate limit reached with a token: You have exceeded a secondary rate limit") do
        client(routes, "t").resolve("some/repo")
      end
    end

    it "raises RateLimited from a tag page too" do
      routes = {TAGS_PAGE_1 => message(403, "API rate limit exceeded")}
      expect_raises(Donico::Fleet::Versions::Github::RateLimited) { client(routes).resolve("some/repo", "3.6") }
    end

    it "raises RequestError on a forbidden response that is not a rate limit" do
      routes = {"repos/some/repo/releases/latest" => message(403, "Repository access blocked")}
      expect_raises(Donico::Fleet::Versions::Github::RequestError, "GitHub 403: Repository access blocked") do
        client(routes).resolve("some/repo")
      end
    end

    it "raises RequestError on any other status, with GitHub's message" do
      routes = {"repos/some/repo/releases/latest" => message(502, "Bad Gateway")}
      expect_raises(Donico::Fleet::Versions::Github::RequestError, "GitHub 502: Bad Gateway") do
        client(routes).resolve("some/repo")
      end
    end

    it "raises RequestError with an empty message when the error body is not JSON" do
      routes = {"repos/some/repo/releases/latest" => {500, nil.as(JSON::Any?)}}
      expect_raises(Donico::Fleet::Versions::Github::RequestError, "GitHub 500: ") do
        client(routes).resolve("some/repo")
      end
    end

    it "is a Donico::Error, so the command line prints it on one line" do
      Donico::Fleet::Versions::Github::RateLimited.new("x").should be_a Donico::Error
      Donico::Fleet::Versions::Github::RequestError.new("x").should be_a Donico::Error
    end

    it "never puts the token in a raised message" do
      token = "sekret-token-value"
      [
        message(403, "API rate limit exceeded"),
        message(429, "secondary rate limit"),
        message(403, "Repository access blocked"),
        message(502, "Bad Gateway"),
        {500, nil.as(JSON::Any?)},
      ].each do |reply|
        client({"repos/some/repo/releases/latest" => reply}, token).resolve("some/repo")
        fail "expected an error for #{reply[0]}"
      rescue e : Donico::Error
        e.message.to_s.should_not contain token
      end
    end
  end

  describe "the default transport" do
    it "returns the release of a 200 with JSON" do
      with_server(200, %({"tag_name":"v1.2.3"})) do |base|
        http_client(base).resolve("x/y").should eq "1.2.3"
      end
    end

    it "asks for the path under the base" do
      with_server(200, %({"tag_name":"v1.2.3"})) do |base, requests|
        http_client(base).resolve("x/y")
        seen_request(requests)[0].should eq "/repos/x/y/releases/latest"
      end
    end

    it "gives nil on a 404, for the release and the tag" do
      with_server(404, %({"message":"Not Found"}), connections: 2) do |base|
        http_client(base).resolve("x/y").should be_nil
      end
    end

    it "raises RateLimited on a 403 that says rate limit" do
      with_server(403, %({"message":"API rate limit exceeded"})) do |base|
        expect_raises(Donico::Fleet::Versions::Github::RateLimited, "GitHub rate limit reached without GITHUB_TOKEN (60 requests/hour): API rate limit exceeded") do
          http_client(base).resolve("x/y")
        end
      end
    end

    it "gives nil on a 200 whose body is not JSON" do
      with_server(200, "<html>captive portal</html>", connections: 2) do |base|
        http_client(base).resolve("x/y").should be_nil
      end
    end

    it "raises RequestError on a 5xx whose body is not JSON" do
      with_server(502, "<html>Bad Gateway</html>") do |base|
        expect_raises(Donico::Fleet::Versions::Github::RequestError, "GitHub 502: ") do
          http_client(base).resolve("x/y")
        end
      end
    end

    it "does not follow a redirect" do
      with_server(301, %({"message":"Moved Permanently"})) do |base|
        expect_raises(Donico::Fleet::Versions::Github::RequestError, "GitHub 301: Moved Permanently") do
          http_client(base).resolve("x/y")
        end
      end
    end

    it "sends the bearer token and the Accept header when there is a token" do
      with_server(200, %({"tag_name":"v1"})) do |base, requests|
        http_client(base, "sekret-token-value").resolve("x/y")
        headers = seen_request(requests)[1]
        headers["Authorization"].should eq "Bearer sekret-token-value"
        headers["Accept"].should eq "application/vnd.github+json"
      end
    end

    it "sends no Authorization header without a token" do
      with_server(200, %({"tag_name":"v1"})) do |base, requests|
        http_client(base).resolve("x/y")
        headers = seen_request(requests)[1]
        headers.has_key?("Authorization").should be_false
        headers["Accept"].should eq "application/vnd.github+json"
      end
    end

    it "sends no Authorization header with an empty token" do
      with_server(200, %({"tag_name":"v1"})) do |base, requests|
        http_client(base, "").resolve("x/y")
        headers = seen_request(requests)[1]
        headers.has_key?("Authorization").should be_false
      end
    end

    it "keeps the token out of the message of a failure" do
      with_server(500, %({"message":"boom"})) do |base|
        error = expect_raises(Donico::Fleet::Versions::Github::RequestError) do
          http_client(base, "sekret-token-value").resolve("x/y")
        end
        error.message.to_s.should_not contain "sekret-token-value"
      end
    end
  end

  # A statically linked OpenSSL looks for certificates under the prefix of the
  # machine that built it; these are the locations the default transport
  # applies on top of those defaults.
  describe ".ca_locations" do
    no_vars = {} of String => String
    exists = ->(paths : Array(String)) { ->(path : String) { paths.includes?(path) } }

    it "applies SSL_CERT_FILE and SSL_CERT_DIR from the fleet's variables, whatever the platform" do
      vars = {"SSL_CERT_FILE" => "/corp/root.pem", "SSL_CERT_DIR" => "/corp/certs"}
      Donico::Fleet::Versions::Github.ca_locations(vars, true, "/opt/x/cert.pem", exists.call(["/opt/x/cert.pem"])).should eq({"/corp/root.pem", "/corp/certs"})
      Donico::Fleet::Versions::Github.ca_locations(vars, false, "/opt/x/cert.pem", exists.call([] of String)).should eq({"/corp/root.pem", "/corp/certs"})
    end

    it "applies either one alone" do
      Donico::Fleet::Versions::Github.ca_locations({"SSL_CERT_FILE" => "/corp/root.pem"}, false, "/x", exists.call([] of String)).should eq({"/corp/root.pem", nil})
      Donico::Fleet::Versions::Github.ca_locations({"SSL_CERT_DIR" => "/corp/certs"}, false, "/x", exists.call([] of String)).should eq({nil, "/corp/certs"})
    end

    it "takes an empty SSL_CERT_FILE or SSL_CERT_DIR as unset" do
      vars = {"SSL_CERT_FILE" => "", "SSL_CERT_DIR" => ""}
      Donico::Fleet::Versions::Github.ca_locations(vars, false, "/x", exists.call([] of String)).should eq({nil, nil})
    end

    it "falls back on the system bundle on darwin when OpenSSL's default file does not exist" do
      Donico::Fleet::Versions::Github.ca_locations(no_vars, true, "/opt/homebrew/etc/openssl@4/cert.pem", exists.call(["/etc/ssl/cert.pem"])).should eq({"/etc/ssl/cert.pem", nil})
    end

    it "keeps the defaults on darwin when OpenSSL's default file exists" do
      paths = ["/opt/homebrew/etc/openssl@4/cert.pem", "/etc/ssl/cert.pem"]
      Donico::Fleet::Versions::Github.ca_locations(no_vars, true, "/opt/homebrew/etc/openssl@4/cert.pem", exists.call(paths)).should eq({nil, nil})
    end

    it "keeps the defaults on darwin when the system bundle is missing too" do
      Donico::Fleet::Versions::Github.ca_locations(no_vars, true, "/opt/homebrew/etc/openssl@4/cert.pem", exists.call([] of String)).should eq({nil, nil})
    end

    it "keeps the defaults elsewhere than darwin, even when the default file is missing" do
      Donico::Fleet::Versions::Github.ca_locations(no_vars, false, "/usr/local/ssl/cert.pem", exists.call(["/etc/ssl/cert.pem"])).should eq({nil, nil})
    end
  end

  describe "the default transport over https" do
    # No request leaves the machine: the context is built before the
    # connection, and loading a file that does not exist fails there.
    it "applies the SSL_CERT_FILE of the fleet's variables, not the process's" do
      vars = {"SSL_CERT_FILE" => "/nonexistent/donico-spec/cert.pem"}
      github = Donico::Fleet::Versions::Github.new(nil, nil, "https://127.0.0.1:1", vars)
      error = expect_raises(Donico::Fleet::Versions::Github::RequestError) do
        github.resolve("some/repo")
      end
      error.message.to_s.should start_with "GitHub request failed: "
      error.message.to_s.should contain "/nonexistent/donico-spec/cert.pem"
    end
  end
end
