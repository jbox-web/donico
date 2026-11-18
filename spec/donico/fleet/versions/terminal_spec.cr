require "../../../spec_helper"
require "termisu/testing"

# Review focus 5: the text interface interrupted (q, Ctrl-C, an exception in
# the apply phase) gives the terminal back as it found it. Each example runs a
# program on a pseudo-terminal through a shell that records `stty -g` before
# and after it: the terminal modes (raw mode, echo, signals) must come back
# identical, and the byte stream must leave the alternate screen and show the
# cursor again after the last time it entered and hid them.

private ROOT    = File.expand_path(File.join(__DIR__, "..", "..", "..", ".."))
private BINARY  = File.join(ROOT, "bin", "donico-manager")
private HARNESS = File.join(ROOT, "bin", "screen-harness")
private SHIM    = File.join(ROOT, "bin", "ctty-exec")

private ENTER_ALTERNATE = "\e[?1049h"
private LEAVE_ALTERNATE = "\e[?1049l"
private HIDE_CURSOR     = "\e[?25l"
private SHOW_CURSOR     = "\e[?25h"

# Runs the program given as "$@", then writes its pid, its status and
# `stty -g` before and after it into $D, then a mark the spec waits for. The
# program runs in the background of a shell without job control so that its
# pid is known: it stays in the terminal's foreground process group, and it
# reads the terminal through /dev/tty, not through its standard input.
private WRAPPER = %q(stty -g > "$D/before"; "$@" & echo $! > "$D/pid"; wait $!; echo $? > "$D/status"; stty -g > "$D/after"; printf 'DONE-%s' MARK)

private BUILD_LOCK = Mutex.new

# A cold compilation of the harness takes about a minute: five is a hung
# compiler, not a slow one.
private BUILD_TIMEOUT = 5.minutes

# Compiles `source` to `target` unless `target` is newer than every file of
# `inputs`. bin/ is where the project's binaries are built, and it is ignored
# by git. The compiler writes a name of this process's own, renamed onto
# `target` once complete: another session running these specs in the same
# tree never executes a half-written binary.
private def build(source : String, target : String, inputs : Array(String)) : String
  BUILD_LOCK.synchronize do
    built = File.exists?(target) ? File.info(target).modification_time : nil
    stale = built.nil? || inputs.any? { |path| File.file?(path) && File.info(path).modification_time > built }
    compile(source, target) if stale
  end
  target
end

private def compile(source : String, target : String) : Nil
  partial = "#{target}.#{Process.pid}.tmp"
  output = IO::Memory.new
  process = Process.new("crystal", ["build", source, "-o", partial], output: output, error: output, chdir: ROOT)
  finished = Channel(Process::Status).new(1)
  spawn { finished.send(process.wait) }
  status = select
  when result = finished.receive
    result
  when timeout(BUILD_TIMEOUT)
    process.signal(Signal::KILL) rescue nil
    finished.receive
    raise "crystal build #{source} did not end within #{BUILD_TIMEOUT}"
  end
  raise "crystal build #{source} failed:\n#{output}" unless status.success?

  # The debug information of a macOS build sits beside the binary, under
  # its name.
  File.rename("#{partial}.dwarf", "#{target}.dwarf") if File.exists?("#{partial}.dwarf")
  File.rename(partial, target)
ensure
  File.delete?(partial) if partial
  File.delete?("#{partial}.dwarf") if partial
end

private def sources(*patterns : String) : Array(String)
  patterns.flat_map { |pattern| Dir.glob(File.join(ROOT, pattern)) }
end

# The controlling-terminal shim Termisu::Testing launches a program through,
# so that the program's `/dev/tty` is the pseudo-terminal. Built here rather
# than by Termisu, which would leave it in the system's temporary directory.
private def shim : String
  path = build(File.join(ROOT, "lib", "termisu", "src", "termisu", "testing", "ctty_exec.cr"), SHIM,
    sources("lib/termisu/src/termisu/testing/ctty_exec.cr"))
  ENV["TERMISU_CTTY_EXEC"] = path
end

private def harness : String
  build(File.join(ROOT, "spec", "fixtures", "screen_harness.cr"), HARNESS,
    sources("spec/fixtures/screen_harness.cr", "src/**/*.cr", "lib/termisu/src/**/*.cr"))
end

# What a run left behind: the bytes the program wrote on the terminal, its
# status, and the terminal modes before and after it.
private record PtyRun, output : String, status : String, before : String, after : String do
  def screen : Termisu::Testing::Screen
    Termisu::Testing::Screen.new(120, 40).tap(&.feed(output))
  end
end

# The terminal of one run: the bytes come in on a fiber, under a lock, and
# `wait_for` reads them with a bound, so a program that never draws or never
# ends is a failed example, never a hung run.
private class PtySession
  getter dir : String

  def initialize(@dir : String, program : String, args : Array(String))
    @lock = Mutex.new
    @bytes = IO::Memory.new
    @pty = Termisu::Testing::Pty.new("/bin/sh", ["-c", WRAPPER, "sh", program] + args, cols: 120, rows: 40,
      env: {"D" => @dir, "TERM" => "xterm-256color"})
    spawn do
      buffer = Bytes.new(4096)
      loop do
        count = @pty.master.read(buffer)
        break if count == 0
        @lock.synchronize { @bytes.write(buffer[0, count]) }
      end
    rescue IO::Error
      # The master is closed, or the slave hung up: the run is over.
    end
  end

  def text : String
    @lock.synchronize { String.new(@bytes.to_slice) }
  end

  def shows?(pattern : String) : Bool
    Termisu::Testing::Screen.new(120, 40).tap(&.feed(text)).includes?(pattern)
  end

  def wait_for(seconds : Float64 = 20.0, &) : Nil
    deadline = Time.instant + seconds.seconds
    until yield
      fail "timed out after #{seconds}s; the terminal shows:\n#{Termisu::Testing::Screen.new(120, 40).tap(&.feed(text))}" if Time.instant > deadline
      sleep 10.milliseconds
    end
  end

  def write(data : String) : Nil
    @pty.write(data)
  end

  # Sends `signal` to the program itself (not to the shell around it).
  def kill(signal : Signal) : Nil
    path = File.join(@dir, "pid")
    wait_for { File.exists?(path) && !File.read(path).strip.empty? }
    Process.signal(signal, File.read(path).strip.to_i64)
  end

  # Ctrl-C as the terminal sends it in raw mode: the byte, not a signal.
  def ctrl_c : Nil
    write("\u0003")
  end

  def finish : PtyRun
    wait_for { text.includes?("DONE-MARK") }
    PtyRun.new(text, File.read(File.join(@dir, "status")).strip,
      File.read(File.join(@dir, "before")).strip, File.read(File.join(@dir, "after")).strip)
  end

  def close : Nil
    @pty.close
  end
end

private def with_pty(program : String, args : Array(String), & : PtySession ->) : Nil
  shim
  with_tmp_dir do |dir|
    session = PtySession.new(dir, program, args)
    begin
      yield session
    ensure
      session.close
    end
  end
end

# The terminal came back: same modes, alternate screen left and cursor shown
# after the last time they were entered and hidden.
private def restored(run : PtyRun) : Nil
  run.before.should_not be_empty
  run.after.should eq run.before
  entered = run.output.rindex(ENTER_ALTERNATE) || fail "the program never entered the alternate screen"
  (run.output.rindex(LEAVE_ALTERNATE) || -1).should be > entered
  (run.output.rindex(SHOW_CURSOR) || -1).should be > (run.output.rindex(HIDE_CURSOR) || -1)
end

# `crystal spec` compiles the specs, not bin/donico: refuse to run on a binary
# older than one of its sources (same guard as binary_spec).
private def stale_binary : String?
  built = File.info(File.join(ROOT, "bin", "donico")).modification_time
  sources("src/**/*", "shard.yml").find { |path| File.file?(path) && File.info(path).modification_time > built }
end

describe Donico::Fleet::Versions::Terminal do
  it "gives the terminal back when q ends the scan" do
    with_pty(harness, ["held"]) do |session|
      session.wait_for { session.shows?("Scan des images 1/3") }
      session.write("q")
      run = session.finish

      run.status.should eq "0"
      restored(run)
      run.output.should contain "outcome: cancelled"
    end
  end

  it "gives the terminal back when Ctrl-C ends the scan" do
    with_pty(harness, ["held"]) do |session|
      session.wait_for { session.shows?("Scan des images 1/3") }
      session.ctrl_c
      run = session.finish

      run.status.should eq "0"
      restored(run)
      run.output.should contain "outcome: cancelled"
    end
  end

  # An exception that escapes the apply phase leaves the interface through its
  # `ensure`: the error is then printed on a terminal given back, not over the
  # frame.
  it "gives the terminal back when an exception escapes the apply phase" do
    with_pty(harness, ["bump-raises"]) do |session|
      session.wait_for { session.shows?("Mises à jour d'images (2)") }
      session.write("a")
      session.write("\r")
      run = session.finish

      run.status.should_not eq "0"
      restored(run)
      message = run.output.rindex("bump of alpha exploded") || fail "the exception was not printed"
      message.should be > (run.output.rindex(LEAVE_ALTERNATE) || fail "the alternate screen was never left")
      run.output.should_not contain "outcome:"
    end
  end

  it "shows a failed README generation on the rows, then gives the terminal back on q" do
    with_pty(harness, ["readmes-raise"]) do |session|
      session.wait_for { session.shows?("Mises à jour d'images (2)") }
      session.write("a")
      session.write("\r")
      session.wait_for { session.shows?("✗ échec : README regeneration failed") }
      session.wait_for { session.shows?("Cochées : 0/2") }
      session.write("q")
      run = session.finish

      run.status.should eq "0"
      restored(run)
      run.output.should contain "outcome: done"
    end
  end

  # The select footer keeps the failure of the configuration repository, on
  # lines of its own and wrapped, the commands still below it.
  it "draws a failure of the configuration repository whole in the select footer" do
    with_pty(harness, ["config-fails"]) do |session|
      session.wait_for { session.shows?("Mises à jour d'images (2)") }
      session.write("\r")
      session.wait_for { session.shows?("1 commit(s) à pousser (p)") }
      # One wait for the whole footer: a frame is read while it may still be
      # arriving, so its lines are checked together until all are there.
      session.wait_for do
        session.shows?("✗ dépôt de configuration : To example.org:fleet/config.git") &&
          session.shows?("! [remote rejected] master -> master (pre-receive hook declined") &&
          session.shows?("CONTRIBUTING.md)") &&
          session.shows?("quitter")
      end
      session.write("q")
      run = session.finish

      run.status.should eq "0"
      restored(run)
    end
  end

  # SIGTERM, SIGHUP and a SIGINT sent from outside (Ctrl-C at the keyboard is
  # a key in raw mode) do not unwind the stack by default: the interface traps
  # them for the length of its run, ends its loop, gives the terminal back and
  # reports 128 + the signal number.
  {Signal::TERM => "143", Signal::HUP => "129", Signal::INT => "130"}.each do |signal, status|
    it "gives the terminal back on SIG#{signal}, with status #{status}" do
      with_pty(harness, ["held"]) do |session|
        session.wait_for { session.shows?("Scan des images 1/3") }
        session.kill(signal)
        run = session.finish

        run.status.should eq status
        restored(run)
        run.output.should_not contain "outcome:"
      end
    end
  end

  describe "the compiled donico-manager repos update" do
    # The binary's GitHub cannot be pointed elsewhere, and no spec reaches the
    # network: the images of this copy have no github_repo, so the scan makes
    # no request and ends on the empty screen at once.
    it "opens on the controlling terminal and gives it back, on q and on Ctrl-C" do
      ["q", "\u0003"].each do |key|
        with_empty_fleet do |command|
          with_pty("/usr/bin/env", ["-i", "TERM=xterm-256color"] + command) do |session|
            # Both lines in one wait: the frame may still be arriving.
            session.wait_for { session.shows?("Aucune image à afficher.") && session.shows?("une touche pour fermer") }
            session.write(key)
            run = session.finish

            run.status.should eq "0"
            restored(run)
          end
        end
      end
    end

    it "gives the terminal back on SIGTERM and ends with status 143" do
      with_empty_fleet do |command|
        with_pty("/usr/bin/env", ["-i", "TERM=xterm-256color"] + command) do |session|
          session.wait_for { session.shows?("Aucune image à afficher.") }
          session.kill(Signal::TERM)
          run = session.finish

          run.status.should eq "143"
          restored(run)
        end
      end
    end

    # A precondition like "no terminal": one line, status 1, the terminal as
    # it was (Termisu fails before it changes anything).
    it "refuses a terminal without TERM in one line" do
      with_empty_fleet do |command|
        with_pty("/usr/bin/env", ["-i"] + command) do |session|
          run = session.finish

          run.status.should eq "1"
          run.after.should eq run.before
          run.output.should contain "donico-manager: cannot open the terminal: TERM environment variable not set"
          run.output.should_not contain "Unhandled exception"
          run.output.should_not contain ENTER_ALTERNATE
        end
      end
    end
  end

  describe ".key_of" do
    # The bindings of the gem's tui.rb: arrows or j/k, space or x, a, enter or
    # d, p, o, q or Ctrl-C. Anything else is no command.
    it "maps every key of the gem, and nothing else" do
      expected = [
        {Termisu::Input::Key::Up, "Up"}, {Termisu::Input::Key::LowerK, "Up"}, {Termisu::Input::Key::Down, "Down"}, {Termisu::Input::Key::LowerJ, "Down"},
        {Termisu::Input::Key::Space, "Toggle"}, {Termisu::Input::Key::LowerX, "Toggle"}, {Termisu::Input::Key::LowerA, "All"},
        {Termisu::Input::Key::Enter, "Apply"}, {Termisu::Input::Key::LowerD, "Apply"}, {Termisu::Input::Key::LowerP, "Push"}, {Termisu::Input::Key::LowerO, "Open"},
        {Termisu::Input::Key::LowerQ, "Quit"},
        {Termisu::Input::Key::UpperQ, "Other"}, {Termisu::Input::Key::LowerC, "Other"}, {Termisu::Input::Key::LowerZ, "Other"}, {Termisu::Input::Key::Escape, "Other"},
        {Termisu::Input::Key::Left, "Other"}, {Termisu::Input::Key::Tab, "Other"},
      ]
      expected.each do |(termisu_key, screen_key)|
        Donico::Fleet::Versions::Terminal.key_of(Termisu::Event::Key.new(termisu_key)).to_s.should eq(screen_key), "for #{termisu_key}"
      end
    end

    it "reads Ctrl-C as q, and c with another modifier as nothing" do
      ctrl = Termisu::Input::Modifier::Ctrl
      Donico::Fleet::Versions::Terminal.key_of(Termisu::Event::Key.new(Termisu::Input::Key::LowerC, ctrl)).to_s.should eq "Quit"
      Donico::Fleet::Versions::Terminal.key_of(Termisu::Event::Key.new(Termisu::Input::Key::LowerC, Termisu::Input::Modifier::Alt)).to_s.should eq "Other"
    end
  end

  describe "a terminal that cannot be opened" do
    it "is a one-line error naming the cause, raised before anything is drawn" do
      screen = Donico::Fleet::Versions::Screen.new(
        ->(_progress : Donico::Fleet::Versions::Screen::Progress) { [] of Donico::Fleet::Versions::Row },
        ->(rows : Array(Donico::Fleet::Versions::Row), _report : Donico::Fleet::Versions::Screen::Report) { rows },
        ->(rows : Array(Donico::Fleet::Versions::Row), _report : Donico::Fleet::Versions::Screen::Report) { rows },
        ->(_row : Donico::Fleet::Versions::Row) { nil })
      opener = -> : Termisu { raise Termisu::Error.new("TERM environment variable not set") }

      expect_raises(Donico::Error, "cannot open the terminal: TERM environment variable not set") do
        Donico::Fleet::Versions::Terminal.new(screen, opener).run
      end
    end
  end
end

# A copy of the fixture fleet whose images have no github_repo, with a fake
# git first on PATH; yields the `env` arguments that run `repos update` there
# with an invented token.
private def with_empty_fleet(& : Array(String) ->) : Nil
  stale = stale_binary
  stale.should be_nil, "bin/donico is older than #{stale}: run `mise dev:build`"
  with_fixture_fleet do |env|
    Dir.glob(File.join(env.dir, "docker-images", "*", "{donico,danico}.yml")).each do |path|
      File.write(path, File.read_lines(path).reject(&.starts_with?("github_repo:")).join('\n'))
    end
    fake_dir = File.join(env.dir, "fake-bin")
    Dir.mkdir_p(fake_dir)
    File.write(File.join(fake_dir, "git"), "#!/bin/sh\nexit 0\n")
    File.chmod(File.join(fake_dir, "git"), 0o755)
    yield ["PATH=#{fake_dir}:/usr/bin:/bin", "GITHUB_TOKEN=spec-token-not-a-secret",
           "/bin/sh", "-c", %(cd "$1" && exec "$2" repos update), "sh", env.dir, BINARY]
  end
end
