require "../../../spec_helper"
require "../../../../src/donico/fleet/versions/updater"

alias UpdaterOutcome = Donico::Fleet::Outcome
alias UpdaterEvent = {Symbol, String?, String?}

# Every collaborator appends to the one trace, so an example can assert the
# order of the whole pipeline and not only of its parts. The fakes are plain
# classes: the Updater is generic over its collaborators for that reason.
class UpdaterTrace
  getter calls = [] of String
  property bump_results = {} of String => UpdaterOutcome
  property commit_results = {} of String => UpdaterOutcome
  property config_result : UpdaterOutcome = {:ok, nil}
  property push_results = {} of String => UpdaterOutcome
  property config_push_result : UpdaterOutcome = {:ok, nil}
  property readme_error : String? = nil
  property readme_exception : Exception? = nil
  property rows = [] of Donico::Fleet::Versions::Row
end

class FakeUpdaterScanner
  def initialize(@trace : UpdaterTrace)
  end

  def call(& : Int32, Int32 ->) : Array(Donico::Fleet::Versions::Row)
    yield 1, 2
    yield 2, 2
    @trace.rows
  end
end

class FakeUpdaterBumper
  def initialize(@trace : UpdaterTrace)
  end

  def call(row : Donico::Fleet::Versions::Row) : UpdaterOutcome
    @trace.calls << "bump:#{row.image}"
    @trace.bump_results.fetch(row.image, {:ok, nil})
  end
end

class FakeUpdaterCommitter
  def initialize(@trace : UpdaterTrace)
  end

  def commit_image(row : Donico::Fleet::Versions::Row) : UpdaterOutcome
    @trace.calls << "commit:#{row.image}"
    @trace.commit_results.fetch(row.image, {:ok, nil})
  end

  def commit_config(rows : Array(Donico::Fleet::Versions::Row)) : UpdaterOutcome
    @trace.calls << "commit:config(#{rows.map(&.image).join(",")})"
    @trace.config_result
  end

  def push(image : String?) : UpdaterOutcome
    @trace.calls << "push:#{image || "config"}"
    image ? @trace.push_results.fetch(image, {:ok, nil}) : @trace.config_push_result
  end
end

private def row(image : String) : Donico::Fleet::Versions::Row
  Donico::Fleet::Versions::Row.new(image: image, current: "1.0.0", latest: "1.0.1",
    state: Donico::Fleet::Versions::State::Update, repo: "org/#{image}", quoted: false)
end

private def build(trace : UpdaterTrace)
  readmes = -> : Nil do
    trace.calls << "readmes"
    if exception = trace.readme_exception
      raise exception
    end
    if message = trace.readme_error
      raise Donico::Error.new(message)
    end
  end
  Donico::Fleet::Versions::Updater.new(FakeUpdaterScanner.new(trace), FakeUpdaterBumper.new(trace),
    FakeUpdaterCommitter.new(trace), readmes)
end

private def apply(trace : UpdaterTrace, images : Array(String)) : {Array(UpdaterEvent), Array(String)}
  events = [] of UpdaterEvent
  returned = build(trace).apply(images.map { |image| row(image) }) do |status, named, message|
    events << {status, named.try(&.image), message}
  end
  {events, returned.map(&.image)}
end

private def push(trace : UpdaterTrace, images : Array(String)) : {Array(UpdaterEvent), Array(String)}
  events = [] of UpdaterEvent
  returned = build(trace).push(images.map { |image| row(image) }) do |status, named, message|
    events << {status, named.try(&.image), message}
  end
  {events, returned.map(&.image)}
end

describe Donico::Fleet::Versions::Updater do
  describe "#apply ordering" do
    it "bumps everything, regenerates the READMEs once, then commits" do
      trace = UpdaterTrace.new
      apply(trace, ["alpha", "bravo"])

      trace.calls.should eq [
        "bump:alpha", "bump:bravo",
        "readmes",
        "commit:alpha", "commit:bravo",
        "commit:config(alpha,bravo)",
      ]
    end

    it "reports each image once, with its final status, and returns the committed rows" do
      trace = UpdaterTrace.new
      events, returned = apply(trace, ["alpha"])

      events.should eq [{:ok, "alpha", nil}]
      returned.should eq ["alpha"]
    end
  end

  describe "#apply with a failing bump" do
    it "does not commit the image that failed, and keeps it out of the root commit" do
      trace = UpdaterTrace.new
      trace.bump_results["bravo"] = {:fail, "generate-files failed"}
      apply(trace, ["alpha", "bravo"])

      trace.calls.should_not contain "commit:bravo"
      trace.calls.should contain "commit:alpha"
      trace.calls.should contain "commit:config(alpha)"
    end

    it "reports the failure and returns only the committed rows" do
      trace = UpdaterTrace.new
      trace.bump_results["bravo"] = {:fail, "generate-files failed"}
      events, returned = apply(trace, ["alpha", "bravo"])

      events.should eq [{:ok, "alpha", nil}, {:fail, "bravo", "generate-files failed"}]
      returned.should eq ["alpha"]
    end
  end

  describe "#apply when the README regeneration fails" do
    it "commits nothing" do
      trace = UpdaterTrace.new
      trace.readme_error = "template missing"
      apply(trace, ["alpha", "bravo"])

      trace.calls.should eq ["bump:alpha", "bump:bravo", "readmes"]
    end

    it "downgrades every bumped image, with the reason, and returns nothing to push" do
      trace = UpdaterTrace.new
      trace.readme_error = "template missing"
      events, returned = apply(trace, ["alpha", "bravo"])

      events.should eq [
        {:ok, "alpha", nil}, {:ok, "bravo", nil},
        {:fail, "alpha", "README regeneration failed: template missing"},
        {:fail, "bravo", "README regeneration failed: template missing"},
      ]
      returned.should be_empty
    end
  end

  # The rows are already written when the generation runs, so any failure of
  # it, not only a Donico::Error, must downgrade them.
  describe "#apply when the README generation raises something else" do
    {
      "a File::Error"     => -> { File::Error.new("Error writing file: 'README.md': Permission denied", file: "README.md").as(Exception) },
      "a plain Exception" => -> { Exception.new("disk on fire") },
    }.each do |label, build_exception|
      it "downgrades every bumped image and commits nothing when it raises #{label}" do
        trace = UpdaterTrace.new
        exception = build_exception.call
        trace.readme_exception = exception
        events, returned = apply(trace, ["alpha", "bravo"])

        message = "README regeneration failed: #{exception.message}"
        events.should eq [
          {:ok, "alpha", nil}, {:ok, "bravo", nil},
          {:fail, "alpha", message}, {:fail, "bravo", message},
        ]
        returned.should be_empty
        trace.calls.should eq ["bump:alpha", "bump:bravo", "readmes"]
      end
    end
  end

  describe "#apply when every bump fails" do
    it "regenerates nothing and commits nothing" do
      trace = UpdaterTrace.new
      trace.bump_results["alpha"] = {:fail, "boom"}
      _, returned = apply(trace, ["alpha"])

      trace.calls.should eq ["bump:alpha"]
      returned.should be_empty
    end

    it "does nothing at all for an empty selection" do
      trace = UpdaterTrace.new
      events, returned = apply(trace, [] of String)

      trace.calls.should be_empty
      events.should be_empty
      returned.should be_empty
    end
  end

  describe "#apply with a failing commit" do
    it "downgrades the row, leaves it out of the root commit and out of the result" do
      trace = UpdaterTrace.new
      trace.commit_results["alpha"] = {:fail, "pre-commit hook refused"}
      events, returned = apply(trace, ["alpha", "bravo"])

      events.should eq [{:ok, "alpha", nil}, {:ok, "bravo", nil}, {:fail, "alpha", "pre-commit hook refused"}]
      trace.calls.should contain "commit:config(bravo)"
      returned.should eq ["bravo"]
    end
  end

  describe "#apply when the root README commit is refused" do
    it "reports it against the configuration repository, with a nil row" do
      trace = UpdaterTrace.new
      trace.config_result = {:fail, "pre-commit hook refused"}
      events, _ = apply(trace, ["alpha"])

      events.last.should eq({:fail, nil, "pre-commit hook refused"})
    end

    it "says nothing when it went through" do
      trace = UpdaterTrace.new
      events, _ = apply(trace, ["alpha"])

      events.should eq [{:ok, "alpha", nil}]
    end
  end

  describe "#apply with a commit that had nothing to do" do
    it "reports the image as unchanged and keeps it out of the root commit" do
      trace = UpdaterTrace.new
      trace.commit_results["alpha"] = {:skip, nil}
      events, returned = apply(trace, ["alpha", "bravo"])

      events.should contain({:skip, "alpha", nil})
      trace.calls.should contain "commit:config(bravo)"
      returned.should eq ["bravo"]
    end

    it "does not commit the root README when no image moved" do
      trace = UpdaterTrace.new
      trace.commit_results["alpha"] = {:skip, nil}
      apply(trace, ["alpha"])

      trace.calls.none?(&.starts_with?("commit:config")).should be_true
    end
  end

  describe "#push" do
    it "pushes each image repository, then the configuration repository" do
      trace = UpdaterTrace.new
      push(trace, ["alpha", "bravo"])

      trace.calls.should eq ["push:alpha", "push:bravo", "push:config"]
    end

    it "reports each image, then the configuration repository with a nil row" do
      trace = UpdaterTrace.new
      events, returned = push(trace, ["alpha"])

      events.should eq [{:pushed, "alpha", nil}, {:pushed, nil, nil}]
      returned.should eq ["alpha"]
    end

    it "reports a rejected configuration push against a nil row" do
      trace = UpdaterTrace.new
      trace.config_push_result = {:fail, "remote rejected"}
      events, _ = push(trace, ["alpha"])

      events.should eq [{:pushed, "alpha", nil}, {:fail, nil, "remote rejected"}]
    end

    it "reports a rejected image push and still pushes the configuration repository" do
      trace = UpdaterTrace.new
      trace.push_results["alpha"] = {:fail, "non-fast-forward"}
      events, _ = push(trace, ["alpha"])

      events.should eq [{:fail, "alpha", "non-fast-forward"}, {:pushed, nil, nil}]
    end

    it "pushes nothing when there is nothing to push" do
      trace = UpdaterTrace.new
      events, returned = push(trace, [] of String)

      trace.calls.should be_empty
      events.should be_empty
      returned.should be_empty
    end
  end

  describe "#scan" do
    it "delegates to the scanner, forwarding the progress and returning its rows" do
      trace = UpdaterTrace.new
      trace.rows = [row("alpha")]
      progress = [] of {Int32, Int32}
      rows = build(trace).scan { |done, total| progress << {done, total} }

      rows.map(&.image).should eq ["alpha"]
      progress.should eq [{1, 2}, {2, 2}]
    end
  end
end
