require "../../../spec_helper"

private alias Reply = {Int32, JSON::Any?}
private alias Versions = Donico::Fleet::Versions

# A fleet whose workspace is its own root, declaring `images` (YAML list items).
private def manifest_of(images : Array(String)) : String
  "registry:  harbor.example.org/base\ngroup:     git@example.org:factory/images\nworkspace: .\nimages:\n" +
    images.map { |entry| "  - #{entry}\n" }.join
end

private def donico_yml(version : String, repo : String = "traefik/traefik") : String
  <<-YAML
    ---
    image_name: traefik
    github_repo: #{repo}
    matrix:
      - version: #{version}
        distro: trixie

    YAML
end

# `versions` maps a repository to the release it resolves to; any other path is
# a 404, which is "nothing found". `seen` collects the paths asked, under a
# mutex since the lookups may run on several threads.
private def releases(versions : Hash(String, String), seen : Array(String)? = nil, lock : Mutex = Mutex.new) : String -> Reply
  ->(path : String) : Reply do
    lock.synchronize { seen.try(&.<< path) }
    versions.each do |repo, version|
      return {200, JSON.parse(%({"tag_name":"#{version}"}))} if path == "repos/#{repo}/releases/latest"
    end
    {404, JSON.parse(%({"message":"Not Found"}))}
  end
end

private def scan(env : Donico::Env, transport : String -> Reply, pool_size : Int32 = 5, progress : Array({Int32, Int32})? = nil) : Array(Versions::Row)
  github = Versions::Github.new(nil, transport)
  Versions::Scanner.new(fleet_repos_of(env), github, pool_size).call do |done, total|
    progress.try(&.<<({done, total}))
  end
end

# Runs the block's value in a fiber and hands it back through a channel, with a
# bound, so that a defect that blocks is a failed example and never a hang.
private def within(seconds : Float64 = 10.0, &block : -> T) : T forall T
  result = Channel(T | Exception).new(1)
  spawn do
    result.send(block.call)
  rescue e
    result.send(e)
  end
  select
  when value = result.receive
    raise value if value.is_a?(Exception)
    value.as(T)
  when timeout(seconds.seconds)
    raise "timed out after #{seconds}s"
  end
end

describe Versions::Scanner do
  it "keeps the version line regular expression multi-line" do
    match = Versions::Scanner::VERSION_LINE.match!("image_name: x\nmatrix:\n  - version: '4.39'\n")
    {match[1], match[2]}.should eq({"'", "4.39"})
  end

  it "reports an available update" do
    with_fleet(manifest_of(["traefik"]), {"traefik/donico.yml" => donico_yml("3.7.8")}) do |env|
      rows = scan(env, releases({"traefik/traefik" => "v3.7.9"}))
      rows.map { |row| {row.image, row.current, row.latest, row.state} }
        .should eq [{"traefik", "3.7.8", "3.7.9", Versions::State::Update}]
    end
  end

  it "reports an up-to-date image" do
    with_fleet(manifest_of(["traefik"]), {"traefik/donico.yml" => donico_yml("3.7.9")}) do |env|
      scan(env, releases({"traefik/traefik" => "3.7.9"})).first.state.should eq Versions::State::Ok
    end
  end

  # The quoting of the YAML scalar must survive the scan: it is what tells the
  # bumper to write "4.40" and not 4.40 (which YAML would re-read as 4.4).
  it "records whether the version scalar is quoted" do
    files = {"seaweedfs/donico.yml" => donico_yml(%("4.39"), "seaweedfs/seaweedfs"), "traefik/donico.yml" => donico_yml("3.7.8")}
    with_fleet(manifest_of(%w[seaweedfs traefik]), files) do |env|
      rows = scan(env, releases({"seaweedfs/seaweedfs" => "4.40", "traefik/traefik" => "3.7.9"}))
      rows.map { |row| {row.image, row.current, row.quoted} }.should eq [{"seaweedfs", "4.39", true}, {"traefik", "3.7.8", false}]
    end
  end

  it "reads a single-quoted version too" do
    with_fleet(manifest_of(["traefik"]), {"traefik/donico.yml" => donico_yml("'3.7.8'")}) do |env|
      row = scan(env, releases({"traefik/traefik" => "3.7.9"})).first
      {row.current, row.quoted}.should eq({"3.7.8", true})
    end
  end

  it "skips the images that track no upstream version" do
    with_fleet(manifest_of(["commitlint: { check_versions: false }"]), {"commitlint/donico.yml" => donico_yml("1.0.0", "conventional-changelog/commitlint")}) do |env|
      scan(env, releases({} of String => String)).should be_empty
    end
  end

  it "skips an image with no github_repo" do
    with_fleet(manifest_of(["x"]), {"x/donico.yml" => "---\nimage_name: x\nmatrix:\n  - version: 1.0.0\n"}) do |env|
      scan(env, releases({} of String => String)).should be_empty
    end
  end

  it "skips an image whose file has no version line" do
    with_fleet(manifest_of(["x"]), {"x/donico.yml" => "---\ngithub_repo: a/b\nmatrix: []\n"}) do |env|
      scan(env, releases({} of String => String)).should be_empty
    end
  end

  it "reports an unversioned image as unfixed" do
    with_fleet(manifest_of(["mise"]), {"mise/donico.yml" => donico_yml("latest", "jdx/mise")}) do |env|
      row = scan(env, releases({"jdx/mise" => "2026.7.17"})).first
      {row.state, row.current, row.latest}.should eq({Versions::State::Unfixed, "latest", "2026.7.17"})
    end
  end

  it "reports a held image as pinned" do
    with_fleet(manifest_of(["icinga2: { pinned: true }"]), {"icinga2/donico.yml" => donico_yml("2.15.5", "icinga/icinga2")}) do |env|
      row = scan(env, releases({"icinga/icinga2" => "2.16.0"})).first
      {row.state, row.latest}.should eq({Versions::State::Pinned, "2.16.0"})
    end
  end

  it "restricts a constrained image to its minor series" do
    seen = [] of String
    with_fleet(manifest_of([%(loki: { constrain: "3.6" })]), {"loki/donico.yml" => donico_yml("3.6.11", "grafana/loki")}) do |env|
      tags = JSON.parse(%([{"name":"v3.7.0"},{"name":"v3.6.13"},{"name":"v3.6.9"}]))
      transport = ->(path : String) : Reply do
        seen << path
        path == "repos/grafana/loki/tags?per_page=100&page=1" ? {200, tags} : {404, nil}
      end
      row = scan(env, transport).first
      {row.latest, row.state}.should eq({"3.6.13", Versions::State::Update})
      seen.should eq ["repos/grafana/loki/tags?per_page=100&page=1"]
    end
  end

  it "reports a failed lookup as an error rather than dropping the image" do
    with_fleet(manifest_of(["traefik"]), {"traefik/donico.yml" => donico_yml("3.7.8")}) do |env|
      row = scan(env, releases({} of String => String)).first
      {row.state, row.latest}.should eq({Versions::State::Error, nil})
    end
  end

  # Review focus 4: GitHub answering something that is not JSON.
  it "reports an answer that is not JSON as an error row" do
    with_fleet(manifest_of(["traefik"]), {"traefik/donico.yml" => donico_yml("3.7.8")}) do |env|
      row = scan(env, ->(_path : String) : Reply { {200, nil} }).first
      {row.state, row.latest}.should eq({Versions::State::Error, nil})
    end
  end

  it "reports a GitHub error status as an error row" do
    with_fleet(manifest_of(["traefik"]), {"traefik/donico.yml" => donico_yml("3.7.8")}) do |env|
      row = scan(env, ->(_path : String) : Reply { {502, JSON.parse(%({"message":"Bad Gateway"}))} }).first
      {row.state, row.latest}.should eq({Versions::State::Error, nil})
    end
  end

  # The rescue must not name the Github errors alone: a timeout, a reset
  # connection or a TLS failure would otherwise take the whole scan down on one
  # flaky lookup.
  it "isolates a lookup that fails outside the Donico error hierarchy" do
    with_fleet(manifest_of(["traefik"]), {"traefik/donico.yml" => donico_yml("3.7.8")}) do |env|
      row = scan(env, ->(_path : String) : Reply { raise IO::TimeoutError.new("boom") }).first
      {row.state, row.latest}.should eq({Versions::State::Error, nil})
    end
  end

  it "keeps scanning the other images when one lookup dies" do
    files = {"traefik/donico.yml" => donico_yml("3.7.8"), "grafana/donico.yml" => donico_yml("13.1.0", "grafana/grafana")}
    with_fleet(manifest_of(%w[grafana traefik]), files) do |env|
      transport = ->(path : String) : Reply do
        raise IO::Error.new("reset") if path.includes?("traefik/traefik")

        {200, JSON.parse(%({"tag_name":"13.2.0"}))}
      end
      scan(env, transport).map { |row| {row.image, row.state} }
        .should eq [{"grafana", Versions::State::Update}, {"traefik", Versions::State::Error}]
    end
  end

  # A rate limit is not one image's problem: every remaining lookup would fail
  # the same way. Swallowed as an error row, fifty images came out as "API
  # error" and nothing said the scan had simply been throttled.
  it "lets a rate limit through rather than reporting an error row per image" do
    with_fleet(manifest_of(["traefik"]), {"traefik/donico.yml" => donico_yml("3.7.8")}) do |env|
      transport = ->(_path : String) : Reply { {403, JSON.parse(%({"message":"API rate limit exceeded"}))} }
      expect_raises(Versions::Github::RateLimited, "GitHub rate limit reached without GITHUB_TOKEN (60 requests/hour): API rate limit exceeded") do
        scan(env, transport)
      end
    end
  end

  # The scan is left at once, while the other lookups are still held: nothing
  # waits for them, and when they finish their result goes into a channel that
  # has room, so no fiber is left blocked.
  it "leaves the scan on a rate limit without waiting for the lookups in flight" do
    images = (1..6).map { |i| "img#{i}" }
    files = images.to_h { |name| {"#{name}/donico.yml", donico_yml("1.0.0", "o/#{name}")} }
    with_fleet(manifest_of(images), files) do |env|
      limited = Channel(Nil).new
      transport = ->(path : String) : Reply do
        if path.includes?("o/img1/")
          limited.close
          {403, JSON.parse(%({"message":"API rate limit exceeded"}))}
        else
          select
          when limited.receive?
          when timeout(5.seconds)
          end
          {404, nil}
        end
      end
      expect_raises(Versions::Github::RateLimited) { within(3.0) { scan(env, transport, 2) } }
    end
  end

  it "reports progress as each image resolves, from the calling fiber" do
    files = {"traefik/donico.yml" => donico_yml("3.7.8"), "grafana/donico.yml" => donico_yml("13.1.0", "grafana/grafana")}
    with_fleet(manifest_of(%w[grafana traefik]), files) do |env|
      caller_fiber = Fiber.current
      fibers = [] of Fiber
      seen = [] of {Int32, Int32}
      github = Versions::Github.new(nil, releases({} of String => String))
      Versions::Scanner.new(fleet_repos_of(env), github).call do |done, total|
        fibers << Fiber.current
        seen << {done, total}
      end
      seen.should eq [{1, 2}, {2, 2}]
      fibers.all? { |fiber| fiber == caller_fiber }.should be_true
    end
  end

  it "returns the rows sorted by image name" do
    files = {"traefik/donico.yml" => donico_yml("3.7.8"), "grafana/donico.yml" => donico_yml("13.1.0", "grafana/grafana")}
    with_fleet(manifest_of(%w[traefik grafana]), files) do |env|
      scan(env, releases({} of String => String)).map(&.image).should eq %w[grafana traefik]
    end
  end

  it "returns nothing and reports no progress for an empty workspace" do
    with_fleet(manifest_of(["traefik"])) do |env|
      progress = [] of {Int32, Int32}
      scan(env, releases({} of String => String), 5, progress).should be_empty
      progress.should be_empty
    end
  end

  # A donico.yml someone is midway through editing must not abort the scan of
  # the other images: it reads as empty and the image reports nothing.
  it "survives a donico.yml that does not parse" do
    with_fleet(manifest_of(["broken"]), {"broken/donico.yml" => "matrix: [\n"}) do |env|
      scan(env, releases({} of String => String)).should be_empty
    end
  end

  # Like the gem, the scan walks the workspace, not the manifest's list.
  it "scans a cloned directory that the manifest does not declare" do
    files = {"traefik/donico.yml" => donico_yml("3.7.8"), "stray/donico.yml" => donico_yml("1.0.0", "o/stray")}
    with_fleet(manifest_of(["traefik"]), files) do |env|
      rows = scan(env, releases({"traefik/traefik" => "3.7.9", "o/stray" => "1.1.0"}))
      rows.map { |row| {row.image, row.state} }.should eq [{"stray", Versions::State::Update}, {"traefik", Versions::State::Update}]
    end
  end

  it "reads danico.yml like donico.yml" do
    with_fleet(manifest_of(["debuerreotype"]), {"debuerreotype/danico.yml" => donico_yml("2026.7.1", "debuerreotype/debuerreotype")}) do |env|
      scan(env, releases({"debuerreotype/debuerreotype" => "2026.8.1"})).map { |row| {row.image, row.state} }
        .should eq [{"debuerreotype", Versions::State::Update}]
    end
  end

  it "ignores a directory with neither file" do
    with_fleet(manifest_of(["traefik"]), {"traefik/README.md" => "x\n", "traefik/donico.yml.bak" => donico_yml("1.0.0")}) do |env|
      scan(env, releases({} of String => String)).should be_empty
    end
  end

  # At most `pool_size` lookups in flight, on fibers: the transport blocks until
  # released and counts what is inside it with an Atomic; every wait is bounded.
  it "never has more lookups in flight than the pool size" do
    images = (1..12).map { |i| "img#{i}" }
    files = images.to_h { |name| {"#{name}/donico.yml", donico_yml("1.0.0", "o/#{name}")} }
    with_fleet(manifest_of(images), files) do |env|
      release = Channel(Nil).new(12)
      in_flight = Atomic(Int32).new(0)
      peak = Atomic(Int32).new(0)
      transport = ->(_path : String) : Reply do
        now = in_flight.add(1) + 1
        loop do
          seen = peak.get
          break if now <= seen || peak.compare_and_set(seen, now)[1]
        end
        select
        when release.receive
        when timeout(10.seconds)
        end
        in_flight.sub(1)
        {200, JSON.parse(%({"tag_name":"2.0.0"}))}
      end

      finished = Channel(Array(Versions::Row) | Exception).new(1)
      spawn do
        finished.send(scan(env, transport, 5))
      rescue e
        finished.send(e)
      end

      # Wait for the pool to fill, then give a sixth lookup every chance to
      # start before looking.
      deadline = Time.instant + 5.seconds
      while in_flight.get != 5 && Time.instant < deadline
        sleep 5.milliseconds
      end
      sleep 200.milliseconds
      in_flight.get.should eq 5
      peak.get.should eq 5

      12.times { release.send(nil) }
      select
      when result = finished.receive
        raise result if result.is_a?(Exception)
        result.map(&.state).uniq!.should eq [Versions::State::Update]
        result.size.should eq 12
      when timeout(10.seconds)
        fail "the scan did not finish"
      end
      peak.get.should eq 5
    end
  end
end
