require "../../../spec_helper"

private alias Versions = Donico::Fleet::Versions
private alias Key = Donico::Fleet::Versions::Screen::Key
private alias Event = {Symbol, Versions::Row?, String?}

private def row(image : String, state : Versions::State = Versions::State::Update,
                current : String = "1.0.0", latest : String? = "1.0.1") : Versions::Row
  Versions::Row.new(image: image, current: current, latest: latest, state: state, repo: "org/#{image}", quoted: false)
end

# A stand-in for `Updater`, with the same three methods. The scan reports its
# scripted progress, then waits on `hold` when one is given (the scan "in
# flight"), then raises `scan_error` or returns the rows. `apply` and `push`
# report the events their script builds from the rows they are given. They run
# on the screen's worker fibers, possibly on another thread: what they record
# goes under a mutex.
class FakeScreenUpdater
  property progress = [] of {Int32, Int32}
  property hold : Channel(Nil)? = nil
  property scan_error : Exception? = nil
  property apply_error : Exception? = nil
  property apply_script : Proc(Array(Versions::Row), Array(Event)) = ->(rows : Array(Versions::Row)) { rows.map { |row| {:ok, row, nil}.as(Event) } }
  property push_script : Proc(Array(Versions::Row), Array(Event)) = ->(rows : Array(Versions::Row)) { rows.map { |row| {:pushed, row, nil}.as(Event) } + [{:pushed, nil, nil}.as(Event)] }

  def initialize(@rows : Array(Versions::Row))
    @lock = Mutex.new
    @applied = [] of Array(Versions::Row)
    @pushed = [] of Array(Versions::Row)
    @started = [] of String
  end

  def applied : Array(Array(Versions::Row))
    @lock.synchronize { @applied.dup }
  end

  def pushed : Array(Array(Versions::Row))
    @lock.synchronize { @pushed.dup }
  end

  def scan(& : Int32, Int32 ->) : Array(Versions::Row)
    @progress.each { |(done, total)| yield done, total }
    @hold.try(&.receive?)
    if error = @scan_error
      raise error
    end
    @rows
  end

  # The rows whose step was started, in order: a step is "started" before
  # its result is reported.
  def started : Array(String)
    @lock.synchronize { @started.dup }
  end

  def apply(rows : Array(Versions::Row), & : Symbol, Versions::Row?, String? ->) : Array(Versions::Row)
    @lock.synchronize { @applied << rows }
    final = {} of Versions::Row => Symbol
    @apply_script.call(rows).each do |(status, row, message)|
      @lock.synchronize { @started << (row.try(&.image) || "config") }
      final[row] = status if row
      yield status, row, message
    end
    if error = @apply_error
      raise error
    end
    # As `Updater#apply`: the rows that ended with a commit.
    rows.select { |row| final[row]? == :ok }
  end

  def push(rows : Array(Versions::Row), & : Symbol, Versions::Row?, String? ->) : Array(Versions::Row)
    @lock.synchronize { @pushed << rows }
    @push_script.call(rows).each { |(status, row, message)| yield status, row, message }
    rows
  end
end

# The scanner, bumper and committer of a real `Updater`, in one: the scan
# returns the rows, a bump goes through unless scripted to fail, and every
# push is recorded by the name of its repository ("config" for the
# configuration repository). Called from the screen's worker fibers.
class PushLog
  def initialize
    @lock = Mutex.new
    @pushes = [] of String
    @bumps = [] of String
    @failing = [] of String
  end

  # The images whose bump was asked, in order.
  def bumps : Array(String)
    @lock.synchronize { @bumps.dup }
  end

  def pushes : Array(String)
    @lock.synchronize { @pushes.dup }
  end

  # The next bump of `image` fails (once), the following ones go through.
  def fail_bump(image : String, once : Bool) : Nil
    @lock.synchronize { @failing << image if once }
  end

  def scan(rows : Array(Versions::Row)) : Array(Versions::Row)
    rows
  end

  def bump(row : Versions::Row) : Donico::Fleet::Outcome
    refused = @lock.synchronize do
      @bumps << row.image
      @failing.delete(row.image)
    end
    refused ? {:fail, "#{row.image} refused"} : {:ok, nil}
  end

  def push(image : String?) : Donico::Fleet::Outcome
    @lock.synchronize { @pushes << (image || "config") }
    {:ok, nil}
  end

  record Scanner, log : PushLog, rows : Array(Versions::Row) do
    def call(& : Int32, Int32 ->) : Array(Versions::Row)
      log.scan(rows)
    end
  end

  record Bumper, log : PushLog do
    def call(row : Versions::Row) : Donico::Fleet::Outcome
      log.bump(row)
    end
  end

  record Committer, log : PushLog do
    def commit_image(row : Versions::Row) : Donico::Fleet::Outcome
      {:ok, nil}
    end

    def commit_config(rows : Array(Versions::Row)) : Donico::Fleet::Outcome
      {:ok, nil}
    end

    def push(image : String?) : Donico::Fleet::Outcome
      log.push(image)
    end
  end
end

# A screen over the real `Updater`, past its scan.
private def ready_over_updater(rows : Array(Versions::Row), log : PushLog) : Versions::Screen
  updater = Versions::Updater.new(PushLog::Scanner.new(log, rows), PushLog::Bumper.new(log), PushLog::Committer.new(log), -> { nil })
  screen = Versions::Screen.new(updater, ->(_row : Versions::Row) { nil })
  tick_until(screen) { screen.phase != :loading }
  screen
end

# Ticks the screen until the block holds, within a bound: a screen that never
# gets there is a failed example, never a hung run.
private def tick_until(screen : Versions::Screen, seconds : Float64 = 5.0, &) : Nil
  deadline = Time.instant + seconds.seconds
  until yield
    fail "the screen did not get there within #{seconds}s (phase #{screen.phase})" if Time.instant > deadline
    screen.tick
    sleep 1.millisecond
  end
end

private def screen_of(updater : FakeScreenUpdater, opened : Array(Versions::Row) = [] of Versions::Row) : Versions::Screen
  Versions::Screen.new(updater, ->(row : Versions::Row) { opened << row; nil })
end

# A screen past its scan, on the select phase (or empty, without rows).
private def ready(rows : Array(Versions::Row), updater : FakeScreenUpdater = FakeScreenUpdater.new(rows),
                  opened : Array(Versions::Row) = [] of Versions::Row) : Versions::Screen
  screen = screen_of(updater, opened)
  tick_until(screen) { screen.phase != :loading }
  screen
end

# Runs a started apply or push to its end, back on the select phase.
private def finish_batch(screen : Versions::Screen) : Nil
  tick_until(screen) { screen.phase == :select }
end

private def press(screen : Versions::Screen, *keys : Key) : Nil
  keys.each { |key| screen.key(key) }
end

private def images(rows : Array(Versions::Row)) : Array(String)
  rows.map(&.image)
end

describe Donico::Fleet::Versions::Screen do
  describe "the loading phase" do
    it "starts on the scan, then moves to select with the rows" do
      updater = FakeScreenUpdater.new([row("alpha")])
      screen = screen_of(updater)
      screen.phase.should eq :loading

      tick_until(screen) { screen.phase != :loading }
      screen.phase.should eq :select
      images(screen.rows).should eq ["alpha"]
      screen.finished?.should be_false
    end

    it "moves to empty when the scan found nothing" do
      ready([] of Versions::Row).phase.should eq :empty
    end

    it "reports the scan counter and its ratio as the scan advances" do
      hold = Channel(Nil).new
      updater = FakeScreenUpdater.new([row("alpha")])
      updater.progress = [{1, 5}, {3, 5}]
      updater.hold = hold
      screen = screen_of(updater)

      screen.footer_title.should eq "Scan des images 0/?"
      screen.progress.should eq 0.0
      tick_until(screen) { screen.scan_done == 3 }
      screen.footer_title.should eq "Scan des images 3/5"
      screen.progress.should eq 0.6
      screen.phase.should eq :loading
      hold.close
    end

    # Ctrl-C reaches the screen as the same key: the terminal maps both.
    it "finishes at once on q during the scan, its results unread" do
      hold = Channel(Nil).new
      updater = FakeScreenUpdater.new([row("alpha")])
      updater.progress = [{1, 2}]
      updater.hold = hold
      screen = screen_of(updater)
      tick_until(screen) { screen.scan_done == 1 }

      screen.key(Key::Quit)
      screen.finished?.should be_true
      screen.outcome.should eq :cancelled
      hold.close
      10.times { screen.tick; sleep 1.millisecond }
      screen.rows.should be_empty
      screen.phase.should eq :loading
    end

    it "ignores the other keys during the scan" do
      hold = Channel(Nil).new
      updater = FakeScreenUpdater.new([row("alpha")])
      updater.hold = hold
      screen = screen_of(updater)
      press(screen, Key::Down, Key::Toggle, Key::Apply, Key::Other)
      screen.finished?.should be_false
      screen.phase.should eq :loading
      hold.close
    end

    it "raises in the caller of tick what ended the scan" do
      updater = FakeScreenUpdater.new([row("alpha")])
      updater.scan_error = Versions::Github::RateLimited.new("GitHub rate limit reached with a token: wait")
      screen = screen_of(updater)

      expect_raises(Versions::Github::RateLimited, "GitHub rate limit reached with a token: wait") do
        tick_until(screen) { false }
      end
    end
  end

  describe "the empty phase" do
    it "closes on any key, and opens nothing" do
      opened = [] of Versions::Row
      screen = ready([] of Versions::Row, opened: opened)
      screen.key(Key::Open)
      screen.finished?.should be_true
      screen.outcome.should eq :cancelled
      opened.should be_empty

      other = ready([] of Versions::Row)
      other.key(Key::Other)
      other.finished?.should be_true
    end
  end

  describe "row order" do
    it "puts updates first, then errors, then unfixed, pinned and up-to-date" do
      screen = ready([row("e", Versions::State::Ok), row("d", Versions::State::Pinned), row("c", Versions::State::Unfixed),
                      row("b", Versions::State::Error), row("a")])
      images(screen.rows).should eq %w[a b c d e]
    end

    it "sorts by image name inside a category" do
      images(ready([row("zulu"), row("alpha")]).rows).should eq %w[alpha zulu]
    end
  end

  describe "navigation" do
    it "moves down and wraps around" do
      screen = ready([row("alpha"), row("bravo"), row("charlie")])
      press(screen, Key::Down, Key::Down, Key::Down)
      screen.cursor.should eq 0
    end

    it "wraps up from the first row to the last" do
      screen = ready([row("alpha"), row("bravo"), row("charlie")])
      screen.key(Key::Up)
      screen.cursor.should eq 2
    end

    it "ignores unknown keys" do
      screen = ready([row("alpha"), row("bravo")])
      screen.key(Key::Other)
      screen.cursor.should eq 0
      screen.phase.should eq :select
      screen.finished?.should be_false
    end

    it "quits on q (and Ctrl-C, which the terminal maps to the same key)" do
      screen = ready([row("alpha")])
      screen.key(Key::Quit)
      screen.finished?.should be_true
      screen.outcome.should eq :cancelled
    end
  end

  describe "selection" do
    it "toggles the current row" do
      screen = ready([row("alpha"), row("bravo"), row("charlie")])
      screen.key(Key::Toggle)
      screen.selected?(0).should be_true
      screen.key(Key::Toggle)
      screen.selected?(0).should be_false
    end

    it "selects every actionable row then clears with a" do
      screen = ready([row("alpha"), row("bravo"), row("charlie")])
      screen.key(Key::All)
      (0..2).map { |index| screen.selected?(index) }.should eq [true, true, true]
      screen.key(Key::All)
      (0..2).map { |index| screen.selected?(index) }.should eq [false, false, false]
    end

    # An image that is up to date, pinned, unfixed or in error has no bump to
    # apply: it is shown for information and must not be selectable.
    it "refuses to toggle a row that is not an update, and a selects only updates" do
      screen = ready([row("upd"), row("okk", Versions::State::Ok), row("err", Versions::State::Error)])
      images(screen.rows).should eq %w[upd err okk]
      screen.selectable?(1).should be_false
      press(screen, Key::Down, Key::Toggle)
      screen.selected?(1).should be_false

      screen.key(Key::All)
      (0..2).map { |index| screen.selected?(index) }.should eq [true, false, false]
    end

    it "counts the checked rows over the updates" do
      screen = ready([row("alpha"), row("bravo"), row("okk", Versions::State::Ok)])
      screen.selection_text.should eq "Cochées : 0/2"
      screen.key(Key::Toggle)
      screen.selection_text.should eq "Cochées : 1/2"
    end
  end

  describe "starting the apply phase" do
    it "falls back to the highlighted row when nothing is selected" do
      updater = FakeScreenUpdater.new([row("alpha"), row("bravo"), row("charlie")])
      screen = ready([] of Versions::Row, updater)
      press(screen, Key::Up, Key::Apply)
      screen.phase.should eq :apply
      finish_batch(screen)
      updater.applied.map { |batch| images(batch) }.should eq [["charlie"]]
    end

    it "keeps an explicit selection" do
      updater = FakeScreenUpdater.new([row("alpha"), row("bravo"), row("charlie")])
      screen = ready([] of Versions::Row, updater)
      press(screen, Key::Toggle, Key::Up, Key::Toggle, Key::Down, Key::Apply)
      finish_batch(screen)
      updater.applied.map { |batch| images(batch) }.should eq [["alpha", "charlie"]]
    end

    it "does nothing when the highlighted row is not actionable" do
      updater = FakeScreenUpdater.new([row("okk", Versions::State::Ok)])
      screen = ready([] of Versions::Row, updater)
      screen.key(Key::Apply)
      screen.phase.should eq :select
      10.times { screen.tick; sleep 1.millisecond }
      updater.applied.should be_empty
    end
  end

  describe "the apply phase" do
    it "advances one image per tick, then returns to select with the selection cleared" do
      updater = FakeScreenUpdater.new([row("alpha"), row("bravo")])
      updater.apply_script = ->(rows : Array(Versions::Row)) { [{:ok, rows[0], nil}, {:fail, rows[1], "generate-files failed"}] of Event }
      screen = ready([] of Versions::Row, updater)
      press(screen, Key::All, Key::Apply)

      screen.state_text(0).should eq "⟳ bump…"
      screen.state_text(1).should eq "· en attente"
      screen.state_color(0).should eq :yellow
      screen.state_color(1).should eq :dim

      tick_until(screen) { screen.state_text(0) == "✓ bumpé" }
      screen.state_text(1).should eq "⟳ bump…"
      screen.state_color(0).should eq :green
      screen.footer_title.should eq "Bump 1/2 · ✓1 ✗0"
      screen.progress.should eq 0.5

      tick_until(screen) { screen.state_text(1) != "⟳ bump…" }
      screen.state_text(1).should eq "✗ échec : generate-files failed"
      screen.state_color(1).should eq :red
      screen.footer_title.should eq "Bump 2/2 · ✓1 ✗1"
      screen.progress_color.should eq :red

      finish_batch(screen)
      screen.selected?(0).should be_false
      screen.outcome.should eq :done
      screen.finished?.should be_false
    end

    it "titles the progress with the batch's counts" do
      updater = FakeScreenUpdater.new([row("alpha"), row("bravo"), row("charlie")])
      updater.apply_script = ->(rows : Array(Versions::Row)) { [{:ok, rows[0], nil}, {:fail, rows[1], "boom"}] of Event }
      screen = ready([] of Versions::Row, updater)
      press(screen, Key::All, Key::Apply)
      tick_until(screen) { screen.state_text(1).starts_with?("✗") }
      screen.footer_title.should eq "Bump 2/3 · ✓1 ✗1"
      screen.progress_color.should eq :red
    end

    it "shows a skipped bump as unchanged" do
      updater = FakeScreenUpdater.new([row("alpha")])
      updater.apply_script = ->(rows : Array(Versions::Row)) { [{:skip, rows[0], nil}] of Event }
      screen = ready([] of Versions::Row, updater)
      screen.key(Key::Apply)
      finish_batch(screen)
      screen.state_text(0).should eq "= inchangé"
      screen.state_color(0).should eq :dim
      screen.footer_title.should eq "Bump 1/1 · ✓0 ✗0"
    end

    # The apply pipeline reports a row twice when a later step downgrades it
    # (the bump succeeded, its commit then failed). Counting distinct rows
    # rather than results keeps the progress bar honest.
    it "corrects a row's state without double-counting it" do
      updater = FakeScreenUpdater.new([row("alpha")])
      updater.apply_script = ->(rows : Array(Versions::Row)) { [{:ok, rows[0], nil}, {:fail, rows[0], "commit failed"}] of Event }
      screen = ready([] of Versions::Row, updater)
      screen.key(Key::Apply)
      finish_batch(screen)
      screen.footer_title.should eq "Bump 1/1 · ✓0 ✗1"
      screen.state_text(0).should eq "✗ échec : commit failed"
    end

    # The fleet's own repository is reported with a nil row: it carries the
    # root README and has no line in the table. Counting it would push the bar
    # past its total; dropping it would hide a failure of the very file that
    # describes the bumps.
    it "keeps a nil row out of the progress count and names it in the title" do
      updater = FakeScreenUpdater.new([row("alpha")])
      updater.apply_script = ->(rows : Array(Versions::Row)) { [{:ok, rows[0], nil}, {:fail, nil, "remote rejected"}] of Event }
      screen = ready([] of Versions::Row, updater)
      screen.key(Key::Apply)
      tick_until(screen) { screen.progress_color == :red }
      screen.progress.should eq 1.0
      screen.footer_title.should eq "Bump 1/1 · ✓1 ✗0 · ✗ dépôt de configuration : remote rejected"
    end

    # The gem shows that failure in the gauge title alone, which the select
    # footer replaces as soon as the batch ends: the owner kept it on screen.
    it "keeps a failure of the configuration repository on screen after the batch, until its push succeeds" do
      updater = FakeScreenUpdater.new([row("alpha")])
      updater.apply_script = ->(rows : Array(Versions::Row)) { [{:ok, rows[0], nil}, {:fail, nil, "remote rejected"}] of Event }
      screen = ready([] of Versions::Row, updater)
      screen.config_alert.should be_nil
      screen.key(Key::Apply)
      finish_batch(screen)
      10.times { screen.tick; sleep 1.millisecond }

      screen.phase.should eq :select
      screen.config_alert.should eq "✗ dépôt de configuration : remote rejected"

      screen.key(Key::Push)
      finish_batch(screen)
      screen.config_alert.should be_nil
    end

    it "keeps it through a batch that commits nothing, and drops it once a later apply commits the README" do
      updater = FakeScreenUpdater.new([row("alpha"), row("bravo")])
      # Three batches of one row each: alpha with its README commit refused,
      # then bravo failing, then bravo going through.
      batch = Atomic(Int32).new(0)
      updater.apply_script = ->(rows : Array(Versions::Row)) do
        case batch.add(1)
        when 0 then [{:ok, rows[0], nil}, {:fail, nil, "hook declined"}] of Event
        when 1 then [{:fail, rows[0], "boom"}] of Event
        else        [{:ok, rows[0], nil}] of Event
        end
      end
      screen = ready([] of Versions::Row, updater)
      screen.key(Key::Apply)
      finish_batch(screen)
      screen.config_alert.should eq "✗ dépôt de configuration : hook declined"

      # A batch whose bumps all fail commits nothing, the README included.
      press(screen, Key::Down, Key::Apply)
      finish_batch(screen)
      screen.config_alert.should eq "✗ dépôt de configuration : hook declined"

      screen.key(Key::Apply)
      finish_batch(screen)
      screen.config_alert.should be_nil
    end

    it "is green while healthy" do
      updater = FakeScreenUpdater.new([row("alpha"), row("bravo")])
      updater.apply_script = ->(rows : Array(Versions::Row)) { [{:ok, rows[0], nil}] of Event }
      screen = ready([] of Versions::Row, updater)
      press(screen, Key::All, Key::Apply)
      tick_until(screen) { screen.state_text(0) == "✓ bumpé" }
      screen.progress_color.should eq :green
    end

    it "raises in the caller of tick what escaped the apply" do
      updater = FakeScreenUpdater.new([row("alpha")])
      updater.apply_error = File::Error.new("Permission denied", file: "README.md")
      screen = ready([] of Versions::Row, updater)
      screen.key(Key::Apply)
      expect_raises(File::Error, "Permission denied") do
        tick_until(screen) { false }
      end
    end

    it "ignores keys while the batch runs" do
      updater = FakeScreenUpdater.new([row("alpha")])
      screen = ready([] of Versions::Row, updater)
      press(screen, Key::Apply, Key::Quit, Key::Down)
      screen.finished?.should be_false
      finish_batch(screen)
      screen.cursor.should eq 0
    end
  end

  # What a signal does through the terminal: the screen ends, the step in
  # progress ends on its own, and no further step starts.
  describe "#interrupt" do
    it "stops an apply after its step in progress, and wait_for_work returns once it has" do
      updater = FakeScreenUpdater.new([row("alpha"), row("bravo"), row("charlie")])
      screen = ready([] of Versions::Row, updater)
      press(screen, Key::All, Key::Apply)
      tick_until(screen) { screen.state_text(0) == "✓ bumpé" }

      screen.interrupt
      done = Channel(Nil).new(1)
      spawn do
        screen.wait_for_work
        done.send(nil)
      end
      select
      when done.receive
      when timeout(5.seconds)
        fail "wait_for_work did not return"
      end
      screen.finished?.should be_true
      updater.started.should eq ["alpha", "bravo"]
    end

    it "returns at once when no apply or push ran" do
      screen = ready([row("alpha")])
      screen.interrupt
      screen.wait_for_work
      screen.finished?.should be_true
    end
  end

  # The push is the irreversible step (the pipeline builds and publishes), so
  # it needs its own key and is unavailable until something was committed.
  describe "the push phase" do
    it "ignores p before anything has been applied" do
      updater = FakeScreenUpdater.new([row("alpha")])
      screen = ready([] of Versions::Row, updater)
      screen.key(Key::Push)
      screen.phase.should eq :select
      10.times { screen.tick; sleep 1.millisecond }
      updater.pushed.should be_empty
    end

    it "hints at the commits to push, then pushes what was applied" do
      updater = FakeScreenUpdater.new([row("alpha"), row("bravo")])
      updater.apply_script = ->(rows : Array(Versions::Row)) { [{:ok, rows[0], nil}, {:fail, rows[1], "boom"}] of Event }
      screen = ready([] of Versions::Row, updater)
      press(screen, Key::All, Key::Apply)
      finish_batch(screen)
      screen.applied_count.should eq 1
      screen.selection_text.should eq "Cochées : 0/2   ·   1 commit(s) à pousser (p)"

      screen.key(Key::Push)
      screen.phase.should eq :push
      # As in the gem: the row being pushed keeps its bump status until its
      # push result comes; only a row with no status yet shows as busy.
      screen.state_text(0).should eq "✓ bumpé"
      screen.state_color(0).should eq :green
      finish_batch(screen)
      updater.pushed.map { |batch| images(batch) }.should eq [["alpha"]]
      screen.state_text(0).should eq "✓ poussé"
      screen.state_color(0).should eq :green
      screen.outcome.should eq :done
    end

    # The push reuses the statuses, which already hold the bump results: the
    # progress counts this batch only, not everything seen so far.
    it "counts the push progress from the push batch alone" do
      updater = FakeScreenUpdater.new([row("alpha"), row("bravo")])
      updater.push_script = ->(rows : Array(Versions::Row)) { [{:pushed, rows[0], nil}] of Event }
      screen = ready([] of Versions::Row, updater)
      press(screen, Key::All, Key::Apply)
      finish_batch(screen)

      screen.key(Key::Push)
      screen.progress.should eq 0.0
      screen.state_text(1).should eq "· en attente"
      tick_until(screen) { screen.state_text(0) == "✓ poussé" }
      screen.progress.should eq 0.5
      screen.footer_title.should eq "Push 1/2 · ✓1 ✗0"
    end

    it "names a failed push of the configuration repository" do
      updater = FakeScreenUpdater.new([row("alpha")])
      updater.push_script = ->(rows : Array(Versions::Row)) { [{:pushed, rows[0], nil}, {:fail, nil, "rejected"}] of Event }
      screen = ready([] of Versions::Row, updater)
      screen.key(Key::Apply)
      finish_batch(screen)
      screen.key(Key::Push)
      tick_until(screen) { screen.progress_color == :red }
      screen.footer_title.should eq "Push 1/1 · ✓1 ✗0 · ✗ dépôt de configuration : rejected"
    end

    # The gem cleared every status at each apply: a second batch made the first
    # one's commits invisible to `p` while the configuration repository's push
    # carried the README of both. The owner keeps them all.
    it "pushes the commits of every batch applied, then the configuration repository" do
      git = PushLog.new
      screen = ready_over_updater([row("alpha"), row("bravo")], git)
      screen.key(Key::Apply)
      finish_batch(screen)
      press(screen, Key::Down, Key::Apply)
      finish_batch(screen)

      screen.state_text(0).should eq "✓ bumpé"
      screen.selection_text.should eq "Cochées : 0/2   ·   2 commit(s) à pousser (p)"
      screen.key(Key::Push)
      finish_batch(screen)
      git.pushes.should eq ["alpha", "bravo", "config"]
      screen.state_text(0).should eq "✓ poussé"
      screen.state_text(1).should eq "✓ poussé"
    end

    it "handles a row that failed in a batch and is applied again as a row of the new batch" do
      git = PushLog.new
      git.fail_bump("bravo", once: true)
      screen = ready_over_updater([row("alpha"), row("bravo")], git)
      press(screen, Key::All, Key::Apply)
      finish_batch(screen)
      screen.state_text(1).should eq "✗ échec : bravo refused"
      screen.selection_text.should eq "Cochées : 0/2   ·   1 commit(s) à pousser (p)"

      press(screen, Key::Down, Key::Apply)
      screen.state_text(1).should eq "⟳ bump…"
      finish_batch(screen)
      screen.state_text(1).should eq "✓ bumpé"
      screen.footer_title.should eq "Bump 1/1 · ✓1 ✗0"
      screen.selection_text.should eq "Cochées : 0/2   ·   2 commit(s) à pousser (p)"

      screen.key(Key::Push)
      finish_batch(screen)
      git.pushes.should eq ["alpha", "bravo", "config"]
    end

    it "leaves a pushed row pushed, and out of the next push" do
      git = PushLog.new
      screen = ready_over_updater([row("alpha"), row("bravo")], git)
      screen.key(Key::Apply)
      finish_batch(screen)
      screen.key(Key::Push)
      finish_batch(screen)
      press(screen, Key::Down, Key::Apply)
      finish_batch(screen)

      screen.state_text(0).should eq "✓ poussé"
      screen.selection_text.should eq "Cochées : 0/2   ·   1 commit(s) à pousser (p)"
      screen.key(Key::Push)
      finish_batch(screen)
      git.pushes.should eq ["alpha", "config", "bravo", "config"]
    end

    # A row committed and waiting for its push is no longer at its scanned
    # version: applied again, the bumper would refuse it as stale, and that
    # failure would take its commit out of the push.
    it "does not apply again a row already committed, and still pushes its commit" do
      git = PushLog.new
      screen = ready_over_updater([row("alpha"), row("bravo")], git)
      screen.key(Key::Apply)
      finish_batch(screen)
      screen.selectable?(0).should be_false

      press(screen, Key::All, Key::Apply)
      finish_batch(screen)
      git.bumps.should eq ["alpha", "bravo"]
      screen.state_text(0).should eq "✓ bumpé"
      screen.key(Key::Push)
      finish_batch(screen)
      git.pushes.should eq ["alpha", "bravo", "config"]
    end

    it "does not offer a pushed row for another apply" do
      git = PushLog.new
      screen = ready_over_updater([row("alpha")], git)
      screen.key(Key::Apply)
      finish_batch(screen)
      screen.key(Key::Push)
      finish_batch(screen)
      screen.selectable?(0).should be_false
      screen.key(Key::Apply)
      screen.phase.should eq :select
      screen.state_text(0).should eq "✓ poussé"
    end

    it "does not offer to push a row whose bump failed" do
      updater = FakeScreenUpdater.new([row("alpha")])
      updater.apply_script = ->(rows : Array(Versions::Row)) { [{:fail, rows[0], "boom"}] of Event }
      screen = ready([] of Versions::Row, updater)
      screen.key(Key::Apply)
      finish_batch(screen)
      screen.key(Key::Push)
      screen.phase.should eq :select
      screen.selection_text.should eq "Cochées : 0/1"
    end
  end

  describe "the table" do
    it "shows each category label once per group, the five of them" do
      screen = ready([row("upd1"), row("upd2"), row("err", Versions::State::Error), row("unf", Versions::State::Unfixed),
                      row("pin", Versions::State::Pinned), row("okk", Versions::State::Ok)])
      (0..5).map { |index| screen.category_label(index) }.should eq ["🔴 MAJ", "", "⚠️ erreur", "📌 latest", "📎 figée", "✅ à jour"]
    end

    it "inserts a blank line before each new group, never before the first row" do
      screen = ready([row("upd1"), row("upd2"), row("okk", Versions::State::Ok)])
      (0..2).map { |index| screen.top_margin(index) }.should eq [0, 0, 1]
    end

    it "flags a non-patch bump, which may need a Dockerfile change, and leaves a patch unmarked" do
      screen = ready([row("lego", current: "5.2.2", latest: "5.3.1"), row("traefik", current: "3.7.8", latest: "3.7.9")])
      screen.kind_label(0).should eq "minor"
      screen.kind_label(1).should eq ""
    end

    it "titles the table with the number of rows, and leaves the state blank while selecting" do
      screen = ready([row("alpha"), row("bravo")])
      screen.table_title.should eq "Mises à jour d'images (2)"
      screen.state_text(0).should eq ""
      screen.state_color(0).should eq :dim
    end
  end

  describe "the o key" do
    # The gem's opener ran with its output thrown away and its failure
    # ignored: a machine without a browser opener must not end a session that
    # may hold commits not pushed yet.
    it "leaves the screen where it was when the opener fails" do
      updater = FakeScreenUpdater.new([row("alpha")])
      screen = Versions::Screen.new(updater, ->(_row : Versions::Row) { raise Donico::EnvironmentError.new("xdg-open not found in PATH") })
      tick_until(screen) { screen.phase != :loading }

      screen.key(Key::Open)
      screen.phase.should eq :select
      screen.finished?.should be_false
      screen.cursor.should eq 0
    end

    it "opens the row under the cursor" do
      opened = [] of Versions::Row
      screen = ready([row("alpha"), row("bravo")], opened: opened)
      press(screen, Key::Down, Key::Open)
      images(opened).should eq ["bravo"]
    end
  end
end
