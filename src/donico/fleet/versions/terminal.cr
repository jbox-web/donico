require "termisu"
require "../../error"
require "./screen"

module Donico
  module Fleet
    module Versions
      # Draws a `Screen` on the terminal with Termisu and feeds it the keys:
      # the drawing half of the gem's `tui.rb`, its layout, labels, columns,
      # widths and colours. The table (or a message) fills the screen above a
      # four-line footer: the commands while selecting, a gauge while the scan,
      # an apply or a push runs. While the configuration repository's last
      # commit or push failed, the select footer grows by the lines that say
      # so (the gem has no such lines, see `Screen#config_alert`).
      #
      # Termisu opens the controlling terminal (`/dev/tty`), enters raw mode and
      # the alternate screen. `run` gives all of it back in an `ensure`,
      # whatever ends the loop: q, Ctrl-C (a key in raw mode, not a signal) or
      # an exception raised by `Screen#tick`, a rate limit among them, or
      # SIGTERM, SIGHUP and a SIGINT sent from outside (`kill -INT`), trapped
      # for the length of the run (by default they kill the process without
      # unwinding, raw mode left on). Nothing else writes to the terminal
      # while it runs.
      class Terminal
        CONTROLS = [
          {"^/v", " nav   "}, {"espace/x", " cocher   "}, {"a", " tout   "},
          {"entrée", " appliquer   "}, {"p", " pousser   "}, {"o", " upstream   "}, {"q", " quitter"},
        ]

        HEADER = ["", "CATÉGORIE", "IMAGE", "", "ACTUELLE", "LATEST", "ÉTAT"]

        # The table's columns: check box, category, image, bump kind, current,
        # latest; the state takes what is left.
        WIDTHS = [3, 10, 20, 6, 12, 12]

        # Columns between two cells, and in front of every row the room of the
        # cursor's mark.
        SPACING          = 1
        HIGHLIGHT_SYMBOL = "> "

        FOOTER_HEIGHT = 4

        # The title of the message and hint blocks, as the gem has it.
        TITLE = "ci-config"

        # How long the loop waits for a key before it ticks the screen again:
        # short while the scan runs, so its counter stays live; longer when
        # only a key can change anything.
        SCAN_WAIT   = 10.milliseconds
        SELECT_WAIT = 100.milliseconds

        # The pause between two results of an apply or a push.
        WORK_WAIT = 10.milliseconds

        # Raised by `run` once the terminal is given back, when SIGTERM, SIGHUP
        # or SIGINT ended it: the command line answers 128 + the signal number,
        # as `Inspec` does. Not a `Donico::Error`: there is nothing to print.
        class Interrupted < Exception
          getter signal : Signal

          def initialize(@signal : Signal)
            super("interrupted by SIG#{signal}")
          end
        end

        # `open_terminal` is the seam of the start-up failures (no TERM, no
        # /dev/tty): the specs reach them without a terminal.
        def initialize(@screen : Screen, @open_terminal : -> Termisu = -> { Termisu.new })
          @offset = 0
          # Set by the signal handler, which may run on another thread
          # (-Dpreview_mt): an atomic the loop reads, and nothing drawn from
          # the handler.
          @signal = Atomic(Int32).new(0)
        end

        # Runs the screen to its end and returns its outcome, `:cancelled` or
        # `:done`.
        def run : Symbol
          # Termisu logs to /tmp/termisu.log unless its logging is marked as
          # set up already: the binary writes no file of its own outside the
          # fleet.
          Termisu::Logging.configured = true
          termisu = open_terminal
          @signal.set(0)
          trap_signals
          begin
            termisu.hide_cursor
            until @screen.finished? || @signal.get != 0
              draw(termisu)
              step(termisu)
            end
          ensure
            close(termisu)
            reset_signals
          end
          interrupted
          @screen.outcome
        end

        # What Termisu raises at start-up (TERM unset, no terminal to open) is
        # a precondition, reported in one line like "no terminal". Termisu
        # undoes what it had done before raising.
        private def open_terminal : Termisu
          @open_terminal.call
        rescue error : Termisu::Error | IO::Error
          raise Donico::Error.new("cannot open the terminal: #{error.message}")
        end

        # After a hangup the terminal may be gone: giving it back can then
        # fail, and that failure must not hide the signal.
        private def close(termisu : Termisu) : Nil
          termisu.close
        rescue error : Exception
          raise error if @signal.get == 0
        end

        # When a signal ended the loop: a running apply or push is told to
        # stop, its step in progress ends (no bump, commit or push is cut in
        # the middle), then `Interrupted`. The terminal is already back and
        # the signals at their default, so a second signal ends the process
        # at once if that step hangs.
        private def interrupted : Nil
          received = @signal.get
          return if received == 0

          @screen.interrupt
          @screen.wait_for_work
          raise Interrupted.new(Signal.new(received))
        end

        # `Process.on_terminate`, which ameba prefers, cannot be undone and
        # hides which signal arrived (see `Inspec`, which traps for the same
        # reasons).
        private def trap_signals : Nil
          # ameba:disable Lint/SignalTrap
          Signal::TERM.trap { |signal| @signal.set(signal.value) }
          # ameba:disable Lint/SignalTrap
          Signal::HUP.trap { |signal| @signal.set(signal.value) }
          # Ctrl-C at the keyboard is a key in raw mode; this is a SIGINT sent
          # from outside.
          # ameba:disable Lint/SignalTrap
          Signal::INT.trap { |signal| @signal.set(signal.value) }
        end

        private def reset_signals : Nil
          Signal::TERM.reset
          Signal::HUP.reset
          Signal::INT.reset
        end

        # One turn of the loop. While an apply or a push runs, keys are left
        # in Termisu's queue, as the gem did: they are read once the batch is
        # over.
        private def step(termisu : Termisu) : Nil
          case @screen.phase
          when :apply, :push
            sleep WORK_WAIT
          else
            event = termisu.poll_event(@screen.phase == :loading ? SCAN_WAIT : SELECT_WAIT)
            @screen.key(Terminal.key_of(event)) if event.is_a?(Termisu::Event::Key)
          end
          @screen.tick
        end

        # The screen's keys for Termisu's: arrows or j/k, space or x, a, enter
        # or d, p, o, q (and Ctrl-C, read apart). Any other key is `Other`,
        # which only the empty screen reads (any key closes it).
        KEYS = {
          Termisu::Input::Key::Up     => Screen::Key::Up,
          Termisu::Input::Key::LowerK => Screen::Key::Up,
          Termisu::Input::Key::Down   => Screen::Key::Down,
          Termisu::Input::Key::LowerJ => Screen::Key::Down,
          Termisu::Input::Key::Space  => Screen::Key::Toggle,
          Termisu::Input::Key::LowerX => Screen::Key::Toggle,
          Termisu::Input::Key::LowerA => Screen::Key::All,
          Termisu::Input::Key::Enter  => Screen::Key::Apply,
          Termisu::Input::Key::LowerD => Screen::Key::Apply,
          Termisu::Input::Key::LowerP => Screen::Key::Push,
          Termisu::Input::Key::LowerO => Screen::Key::Open,
          Termisu::Input::Key::LowerQ => Screen::Key::Quit,
        }

        def self.key_of(event : Termisu::Event::Key) : Screen::Key
          return Screen::Key::Quit if event.ctrl_c?

          KEYS.fetch(event.key, Screen::Key::Other)
        end

        # --- drawing ---------------------------------------------------------

        private def draw(termisu : Termisu) : Nil
          width, height = termisu.size
          termisu.clear
          alert = alert_lines(width, height)
          top = height - FOOTER_HEIGHT - alert.size
          if width >= 4 && top >= 3
            draw_phase(termisu, width, top, alert)
          end
          termisu.render
        end

        # The failure of the configuration repository, on lines of its own
        # below the selection: appended to the selection line, git's message
        # would be cut at the frame. Wrapped to the footer's width; only a
        # terminal too short to keep three lines of table loses lines.
        private def alert_lines(width : Int32, height : Int32) : Array(String)
          text = @screen.config_alert
          return [] of String unless text && @screen.phase == :select

          wrap(text, width - 2).first(Math.max(0, height - FOOTER_HEIGHT - 3))
        end

        private def draw_phase(termisu : Termisu, width : Int32, top : Int32, alert : Array(String)) : Nil
          case @screen.phase
          when :loading
            message(termisu, width, top, "Scan des versions upstream…")
            gauge(termisu, top, width, @screen.progress, :green, @screen.footer_title)
          when :empty
            message(termisu, width, top, "Aucune image à afficher.")
            box(termisu, 0, top, width, FOOTER_HEIGHT, TITLE)
            put(termisu, 1, top + 1, "une touche pour fermer", width - 2)
          else
            table(termisu, width, top)
            if @screen.phase == :select
              commands(termisu, top, width, alert)
            else
              gauge(termisu, top, width, @screen.progress, @screen.progress_color, @screen.footer_title)
            end
          end
        end

        private def message(termisu : Termisu, width : Int32, height : Int32, text : String) : Nil
          box(termisu, 0, 0, width, height, TITLE)
          put(termisu, 1, 2, "  #{text}", width - 2) if height > 3
        end

        # The gauge: the filled part in the colour, the percentage centred on
        # the second line, written over the fill in the terminal's colour.
        private def gauge(termisu : Termisu, y : Int32, width : Int32, ratio : Float64, color : Symbol, title : String) : Nil
          box(termisu, 0, y, width, FOOTER_HEIGHT, title)
          inner = width - 2
          filled = (inner * ratio.clamp(0.0, 1.0)).to_i
          fg = color_of(color)
          label = "#{(ratio * 100).round(mode: :ties_away).to_i}%"
          label_x = 1 + Math.max(0, (inner - label.size) // 2)
          (1..2).each do |line|
            (0...inner).each do |column|
              x = column + 1
              char = line == 2 && x >= label_x && x < label_x + label.size ? label[x - label_x] : ' '
              if column < filled
                termisu.set_cell(x, y + line, char, fg: Termisu::Color.default, bg: fg)
              else
                termisu.set_cell(x, y + line, char, fg: fg, bg: Termisu::Color.default)
              end
            end
          end
        end

        # The select footer: the checked rows, the failure of the
        # configuration repository in red when there is one, then the
        # commands, their keys bold and underlined.
        private def commands(termisu : Termisu, y : Int32, width : Int32, alert : Array(String)) : Nil
          box(termisu, 0, y, width, FOOTER_HEIGHT + alert.size, "Commandes")
          limit = width - 2
          put(termisu, 1, y + 1, @screen.selection_text, limit)
          alert.each_with_index do |line, index|
            put(termisu, 1, y + 2 + index, line, limit, fg: Termisu::Color.red)
          end
          x = 1
          controls = y + 2 + alert.size
          CONTROLS.each do |(key, label)|
            x = put(termisu, x, controls, key, limit - (x - 1), attr: Termisu::Attribute::Bold | Termisu::Attribute::Underline)
            x = put(termisu, x, controls, label, limit - (x - 1))
          end
        end

        private def table(termisu : Termisu, width : Int32, height : Int32) : Nil
          box(termisu, 0, 0, width, height, @screen.table_title)
          left = 1 + HIGHLIGHT_SYMBOL.size
          widths = column_widths(width - 2 - HIGHLIGHT_SYMBOL.size)
          cells(termisu, left, 1, HEADER, widths)

          visible = height - 3
          return if visible <= 0

          scroll(visible)
          y = 2
          (@offset...@screen.rows.size).each do |index|
            y += @screen.top_margin(index)
            break if y > height - 2

            row(termisu, index, left, y, widths)
            y += 1
          end
        end

        private def row(termisu : Termisu, index : Int32, left : Int32, y : Int32, widths : Array(Int32)) : Nil
          row = @screen.rows[index]
          check = @screen.selectable?(index) ? (@screen.selected?(index) ? "[x]" : "[ ]") : "   "
          texts = [check, @screen.category_label(index), row.image, @screen.kind_label(index),
                   row.display_current, row.latest.to_s, @screen.state_text(index)]
          if index == @screen.cursor
            # The cursor's row is all yellow and bold, its state included.
            highlight = Termisu::Attribute::Bold
            put(termisu, 1, y, HIGHLIGHT_SYMBOL, HIGHLIGHT_SYMBOL.size, fg: Termisu::Color.yellow, attr: highlight)
            cells(termisu, left, y, texts, widths, Termisu::Color.yellow, highlight)
          else
            cells(termisu, left, y, texts[0..-2], widths[0..-2])
            state_fg, state_attr = state_style(index)
            put(termisu, left + widths[0..-2].sum + SPACING * (widths.size - 1), y, texts.last, widths.last,
              fg: state_fg, attr: state_attr)
          end
        end

        private def state_style(index : Int32) : {Termisu::Color, Termisu::Attribute}
          color = @screen.state_color(index)
          return {Termisu::Color.default, Termisu::Attribute::Dim} if color == :dim

          {color_of(color), Termisu::Attribute::None}
        end

        private def cells(termisu : Termisu, left : Int32, y : Int32, texts : Array(String), widths : Array(Int32),
                          fg : Termisu::Color = Termisu::Color.default, attr : Termisu::Attribute = Termisu::Attribute::None) : Nil
          x = left
          texts.each_with_index do |text, column|
            put(termisu, x, y, text, widths[column], fg: fg, attr: attr)
            x += widths[column] + SPACING
          end
        end

        # The fixed widths, then the state column with what is left.
        private def column_widths(room : Int32) : Array(Int32)
          fixed = WIDTHS.sum + SPACING * WIDTHS.size
          WIDTHS + [Math.max(0, room - fixed)]
        end

        # Keeps the cursor's row in view, each row counting its blank line
        # above.
        private def scroll(visible : Int32) : Nil
          cursor = @screen.cursor
          @offset = cursor if cursor < @offset
          while @offset < cursor && lines(@offset..cursor) > visible
            @offset += 1
          end
        end

        private def lines(range : Range(Int32, Int32)) : Int32
          range.sum { |index| 1 + @screen.top_margin(index) }
        end

        # A frame with its title on the top border.
        private def box(termisu : Termisu, x : Int32, y : Int32, width : Int32, height : Int32, title : String) : Nil
          right = x + width - 1
          bottom = y + height - 1
          (x + 1...right).each do |column|
            termisu.set_cell(column, y, '─', fg: Termisu::Color.default)
            termisu.set_cell(column, bottom, '─', fg: Termisu::Color.default)
          end
          (y + 1...bottom).each do |line|
            termisu.set_cell(x, line, '│', fg: Termisu::Color.default)
            termisu.set_cell(right, line, '│', fg: Termisu::Color.default)
          end
          termisu.set_cell(x, y, '┌', fg: Termisu::Color.default)
          termisu.set_cell(right, y, '┐', fg: Termisu::Color.default)
          termisu.set_cell(x, bottom, '└', fg: Termisu::Color.default)
          termisu.set_cell(right, bottom, '┘', fg: Termisu::Color.default)
          put(termisu, x + 1, y, title, width - 2)
        end

        # Writes `text` from column `x` of line `y`, grapheme by grapheme, in at
        # most `width` columns: a label holding `⚠️` or `📌` takes two columns
        # for that grapheme. Returns the column after the text.
        private def put(termisu : Termisu, x : Int32, y : Int32, text : String, width : Int32,
                        fg : Termisu::Color = Termisu::Color.default, attr : Termisu::Attribute = Termisu::Attribute::None) : Int32
          limit = x + width
          text.each_grapheme do |grapheme|
            cluster = grapheme.to_s
            columns = Termisu::UnicodeWidth.grapheme_width(cluster).to_i
            break if x + columns > limit

            termisu.set_cell(x, y, cluster, fg: fg, attr: attr) if columns > 0
            x += columns
          end
          x
        end

        # Cuts `text` into lines of at most `width` columns: at its own line
        # breaks (git's messages have several), then between words; a word
        # wider than a line is cut where the line ends.
        private def wrap(text : String, width : Int32) : Array(String)
          return [] of String if width <= 0

          text.lines.flat_map do |line|
            lines = [] of String
            current = ""
            line.split(' ', remove_empty: true).each do |word|
              candidate = current.empty? ? word : "#{current} #{word}"
              if columns(candidate) <= width
                current = candidate
                next
              end
              lines << current unless current.empty?
              current = word
              while columns(current) > width
                head, current = cut(current, width)
                lines << head
              end
            end
            lines << current unless current.empty?
            lines
          end
        end

        # The head of `text` that fits in `width` columns, and the rest. The
        # head holds at least one grapheme, so cutting always advances.
        private def cut(text : String, width : Int32) : {String, String}
          used = 0
          size = 0
          text.each_grapheme do |grapheme|
            cluster = grapheme.to_s
            columns = Termisu::UnicodeWidth.grapheme_width(cluster).to_i
            break if used + columns > width && size > 0

            used += columns
            size += cluster.size
          end
          {text[0, size], text[size..]}
        end

        private def columns(text : String) : Int32
          text.each_grapheme.sum { |grapheme| Termisu::UnicodeWidth.grapheme_width(grapheme.to_s).to_i }
        end

        private def color_of(color : Symbol) : Termisu::Color
          case color
          when :green  then Termisu::Color.green
          when :red    then Termisu::Color.red
          when :yellow then Termisu::Color.yellow
          else              Termisu::Color.default
          end
        end
      end
    end
  end
end
