require "set"
require "../../error"
require "./row"

module Donico
  module Fleet
    module Versions
      # The state of the `repos update` screen, without a terminal: the gem's
      # `tui.rb` minus its drawing, which is `Terminal`'s. Phases:
      #
      #   :loading -> the scan runs, with a live counter
      #   :select  -> browse and (de)select the images to bump
      #   :apply   -> bump, regenerate and commit, live progress
      #   :push    -> push what was applied, live progress
      #   :empty   -> nothing to show, any key closes
      #
      # The long operations block (`Updater` calls back and waits on git and on
      # GitHub) while the screen must stay drawable. Each runs in a fiber of its
      # own that only sends what `Updater` reports into a channel; `tick` takes
      # one result from it without blocking. Everything else is touched from
      # the one fiber that calls `key` and `tick`, so no state is shared with
      # the workers but the channel.
      #
      # Rows that are not updates are shown for information and cannot be
      # selected.
      class Screen
        # What the screen understands. The terminal maps its keys onto these:
        # arrows or j/k, space or x, a, enter or d, p, o, q or Ctrl-C.
        enum Key
          Up
          Down
          Toggle
          All
          Apply
          Push
          Open
          Quit
          Other
        end

        alias Progress = Int32, Int32 -> Nil
        alias Report = Symbol, Row?, String? -> Nil

        # What a scan worker sends: its progress, then its rows or the
        # exception that ended it.
        private alias ScanEvent = {Int32, Int32} | Array(Row) | Exception

        # What an apply or push worker sends: one result, then the end (the
        # rows the call returned) or the exception that escaped it.
        private alias WorkEvent = {Symbol, Row?, String?} | Array(Row) | Exception

        # Display order: what needs doing first, then anomalies, then
        # information.
        CATEGORY_ORDER = [State::Update, State::Error, State::Unfixed, State::Pinned, State::Ok]

        CATEGORY_LABELS = {
          State::Update => "🔴 MAJ", State::Error => "⚠️ erreur", State::Unfixed => "📌 latest",
          State::Pinned => "📎 figée", State::Ok => "✅ à jour",
        }

        STATUS_TEXT = {:ok => "✓ bumpé", :skip => "= inchangé", :pushed => "✓ poussé"}
        STATUS_FG   = {:ok => :green, :pushed => :green, :fail => :red}

        # The statuses that leave the repository with a commit to push.
        APPLIED_STATUSES = [:ok]
        # The statuses of a row whose commit exists: see `selectable?`.
        COMMITTED_STATUSES = [:ok, :pushed]

        getter phase : Symbol
        getter rows : Array(Row)
        getter cursor : Int32
        getter scan_done : Int32
        getter scan_total : Int32?
        getter done : Int32
        getter total : Int32
        getter outcome : Symbol

        # Builds the three operations from anything that answers `Updater`'s
        # `scan`, `apply` and `push`: the real one in production, a small fake
        # in the specs.
        def self.new(updater, open : Row -> Nil) : self
          new(
            ->(progress : Progress) { updater.scan { |done, total| progress.call(done, total) } },
            ->(rows : Array(Row), report : Report) { updater.apply(rows) { |status, row, message| report.call(status, row, message) } },
            ->(rows : Array(Row), report : Report) { updater.push(rows) { |status, row, message| report.call(status, row, message) } },
            open)
        end

        def initialize(@scan : Progress -> Array(Row), @apply : Array(Row), Report -> Array(Row),
                       @push : Array(Row), Report -> Array(Row), @open : Row -> Nil)
          @phase = :loading
          @rows = [] of Row
          @cursor = 0
          @selected = [] of Int32
          @status = {} of Row => {Symbol, String?}
          @chosen = [] of Row
          @pushable = [] of Row
          @batch_done = Set(Row).new
          @done = 0
          @total = 0
          @scan_done = 0
          @scan_total = nil.as(Int32?)
          @config_status = nil.as({Symbol, String?}?)
          @config_failure = nil.as(String?)
          @outcome = :cancelled
          @finished = false
          @scan_events = nil.as(Channel(ScanEvent)?)
          @work_events = nil.as(Channel(WorkEvent)?)
          @work_done = nil.as(Channel(Nil)?)
        end

        # True once the screen is to be closed: quit, or a key on the empty
        # screen.
        def finished? : Bool
          @finished
        end

        def key(key : Key) : Nil
          return if @finished

          case @phase
          when :loading
            # q or Ctrl-C cancels the scan; its worker ends on its own.
            finish if key.quit?
          when :empty
            finish
          when :select
            handle(key)
          end
        end

        # Advances a scan, an apply or a push by one result, without blocking.
        # The exception that ended the operation is raised here, in the
        # caller's fiber.
        def tick : Nil
          return if @finished

          case @phase
          when :loading
            scan_tick
          when :apply, :push
            work_tick
          end
        end

        # --- what the drawing reads ---------------------------------------

        # An update whose commit is made (waiting for its push, or pushed) is
        # no longer selectable: its `donico.yml` has left the scanned version,
        # so another apply would be refused as stale, and that failure would
        # take the commit out of the push. The gem let it be selected.
        def selectable?(index : Int32) : Bool
          row = @rows[index]?
          return false if row.nil? || !row.update?

          !COMMITTED_STATUSES.includes?(@status[row]?.try(&.first))
        end

        def selected?(index : Int32) : Bool
          @selected.includes?(index)
        end

        # The state column: blank while selecting, then the live status once
        # the work has started. A row still queued in the current batch shows
        # as pending even if a previous batch already gave it a status.
        def state_text(index : Int32) : String
          row = @rows[index]
          if (status = @status[row]?) && !queued?(row)
            return status_text(*status)
          end
          return busy_label if row == current_row
          return "· en attente" if queued?(row)

          ""
        end

        # :green, :red, :yellow (the row being worked on) or :dim.
        def state_color(index : Int32) : Symbol
          row = @rows[index]
          status = @status[row]?.try(&.[0])
          if status && (color = STATUS_FG[status]?)
            return color
          end
          return :yellow if row == current_row

          :dim
        end

        # Rows are grouped by category: the label shows on the first row of
        # each block only.
        def category_label(index : Int32) : String
          group_start?(index) ? CATEGORY_LABELS.fetch(@rows[index].state, "") : ""
        end

        # A blank line before each new group, never before the first row. Rows
        # stay one to one with the data, so the cursor and the selection are
        # unaffected.
        def top_margin(index : Int32) : Int32
          group_start?(index) && index.positive? ? 1 : 0
        end

        # Marks a bump that is not a patch: it may need a Dockerfile or InSpec
        # change.
        def kind_label(index : Int32) : String
          kind = @rows[index].bump_kind
          kind && kind != :patch ? kind.to_s : ""
        end

        def table_title : String
          "Mises à jour d'images (#{@rows.size})"
        end

        # The title of the gauge: the scan counter, or the current batch's.
        def footer_title : String
          @phase == :loading ? scan_title : progress_title
        end

        # The ratio of the gauge, between 0 and 1.
        def progress : Float64
          @phase == :loading ? scan_ratio : progress_ratio
        end

        def progress_color : Symbol
          return :green if @phase == :loading
          return :red if config_failed?

          summary[:failed].positive? ? :red : :green
        end

        # The first line of the select footer: the checked rows over the
        # updates, and a reminder once commits are waiting for a push.
        def selection_text : String
          "Cochées : #{@selected.size}/#{@rows.count(&.update?)}#{push_hint}"
        end

        # The last failure of the configuration repository, for the select
        # footer, or nil. The gem showed it in the gauge title only, which
        # the footer replaces as soon as the batch ends: a refused README
        # commit or push went by in a single tick. This departs from the gem
        # on purpose: the failure stays on screen until a later apply or push
        # of that repository succeeds.
        def config_alert : String?
          @config_failure.try { |message| config_failure_text(message) }
        end

        # The rows whose bump went through, so there is a commit to push.
        def applied_count : Int32
          applied.size
        end

        # --- select phase ---------------------------------------------------

        private def handle(key : Key) : Nil
          return finish if key.quit?
          return if @rows.empty?

          case key
          in .down?
            @cursor = (@cursor + 1) % @rows.size
          in .up?
            @cursor = (@cursor - 1) % @rows.size
          in .toggle?
            toggle(@cursor)
          in .all?
            toggle_all
          in .apply?
            start_apply if choose
          in .push?
            start_push unless applied.empty?
          in .open?
            open(@rows[@cursor])
          in .quit?, .other?
            nil
          end
        end

        # The gem ran its opener with the output thrown away and its failure
        # ignored. A missing opener must not end a session that may hold
        # commits not pushed yet: the screen stays where it was.
        private def open(row : Row) : Nil
          @open.call(row)
        rescue Donico::Error
        end

        private def toggle(index : Int32) : Nil
          return unless selectable?(index)

          @selected.includes?(index) ? @selected.delete(index) : @selected.push(index)
        end

        # Selects every actionable row, or clears the selection when they are
        # all already selected.
        private def toggle_all : Nil
          actionable = (0...@rows.size).select { |index| selectable?(index) }
          if @selected.size == actionable.size
            @selected.clear
          else
            @selected = actionable
          end
        end

        # Turns the selection, or the highlighted row when nothing is
        # selected, into the batch to apply. False when there is nothing
        # actionable.
        private def choose : Bool
          @selected = [@cursor] if @selected.empty? && selectable?(@cursor)
          return false if @selected.empty?

          @chosen = @selected.sort.map { |index| @rows[index] }
          true
        end

        # Ends the screen whatever its phase, as a signal does: a running
        # apply or push is told to stop (see `finish`), and `wait_for_work`
        # lets its step in progress end.
        def interrupt : Nil
          finish
        end

        # Blocks until the apply or push worker has ended, if one ran. Its
        # step in progress (a bump, a push) is not cut in the middle; no
        # further step starts once its channel is closed.
        def wait_for_work : Nil
          @work_done.try(&.receive?)
        end

        private def finish : Nil
          @finished = true
          # A worker still running finds its channel closed at its next send
          # and ends there: its results are not read.
          @scan_events.try(&.close)
          @work_events.try(&.close)
        end

        # --- loading phase --------------------------------------------------

        private def scan_tick : Nil
          events = @scan_events || start_scan
          select
          when event = events.receive?
            receive_scan(event) if event
          else
          end
        end

        private def start_scan : Channel(ScanEvent)
          events = Channel(ScanEvent).new
          @scan_events = events
          scan = @scan
          spawn do
            rows = scan.call(->(done : Int32, total : Int32) { events.send({done, total}); nil })
            events.send(rows)
          rescue Channel::ClosedError
            # The screen was closed during the scan.
          rescue error : Exception
            begin
              events.send(error)
            rescue Channel::ClosedError
            end
          end
          events
        end

        private def receive_scan(event : ScanEvent) : Nil
          case event
          in Exception
            raise event
          in Tuple(Int32, Int32)
            @scan_done, @scan_total = event
          in Array(Row)
            @scan_events = nil
            install(event)
            @phase = @rows.empty? ? :empty : :select
          end
        end

        # Installs the rows in display order: category first, then image name.
        private def install(rows : Array(Row)) : Nil
          @rows = rows.sort_by { |row| {CATEGORY_ORDER.index(row.state) || CATEGORY_ORDER.size, row.image} }
        end

        private def scan_ratio : Float64
          total = @scan_total || 0
          total.zero? ? 0.0 : @scan_done / total
        end

        private def scan_title : String
          "Scan des images #{@scan_done}/#{@scan_total || '?'}"
        end

        # --- apply and push phases ------------------------------------------

        # Clears the statuses of the new batch's rows only. This departs from
        # the gem on purpose: the gem cleared every status, so the commits of
        # an earlier batch not pushed yet were lost to `p` and to the
        # reminder, while the configuration repository's push carried the
        # README of both batches.
        private def start_apply : Nil
          @phase = :apply
          @chosen.each { |row| @status.delete(row) }
          start_batch(@chosen, @apply)
        end

        private def start_push : Nil
          @pushable = applied
          @phase = :push
          start_batch(@pushable, @push)
        end

        private def start_batch(rows : Array(Row), operation : Array(Row), Report -> Array(Row)) : Nil
          @total = rows.size
          @done = 0
          @batch_done = Set(Row).new
          @config_status = nil
          events = Channel(WorkEvent).new
          @work_events = events
          done = Channel(Nil).new
          @work_done = done
          spawn do
            report = ->(status : Symbol, row : Row?, message : String?) { events.send({status, row, message}); nil }
            events.send(operation.call(rows, report))
          rescue Channel::ClosedError
            # The screen was closed during the batch.
          rescue error : Exception
            begin
              events.send(error)
            rescue Channel::ClosedError
            end
          ensure
            done.close
          end
        end

        private def work_tick : Nil
          events = @work_events || return
          select
          when event = events.receive?
            receive_work(event) if event
          else
          end
        end

        private def receive_work(event : WorkEvent) : Nil
          case event
          in Exception
            raise event
          in Tuple(Symbol, Row?, String?)
            record(*event)
          in Array(Row)
            @work_events = nil
            config_committed if @phase == :apply && !event.empty?
            finish_batch
          end
        end

        # Records one result. Progress counts the DISTINCT rows of the current
        # batch: the apply pipeline reports a row a second time when a later
        # step downgrades it (bump ok, commit failed), and the statuses still
        # hold the bump results once the push batch starts.
        private def record(status : Symbol, row : Row?, message : String?) : Nil
          # A nil row is the fleet's own repository: it carries the root README
          # and has no line in the table. Kept out of the counters, which are
          # sized on the batch of images, and shown in the title instead.
          if row.nil?
            @config_status = {status, message}
            @config_failure = status == :fail ? message.to_s : nil
            return
          end

          @status[row] = {status, message}
          @batch_done << row
          @done = @batch_done.size
        end

        private def finish_batch : Nil
          if @phase == :apply
            @selected = [] of Int32
            @outcome = :done
          end
          @phase = :select
        end

        private def applied : Array(Row)
          @status.select { |_, (status, _)| APPLIED_STATUSES.includes?(status) }.keys
        end

        # Counts of the current batch (all recorded results when no batch is
        # running). A pushed row counts as applied: both are successes for the
        # gauge's colour.
        private def summary : NamedTuple(applied: Int32, skipped: Int32, failed: Int32)
          rows = @batch_done.empty? ? @status.keys : @batch_done.to_a
          counts = Hash(Symbol, Int32).new(0)
          rows.each { |row| counts[@status[row][0]] += 1 }
          {applied: counts[:ok] + counts[:pushed], skipped: counts[:skip], failed: counts[:fail]}
        end

        # The rows of the current phase's batch.
        private def batch : Array(Row)
          @phase == :push ? @pushable : @chosen
        end

        # The row being worked on: the first of the batch without a result yet
        # (the work is sequential), shown busy while it blocks.
        private def current_row : Row?
          return if @phase == :select || @phase == :loading || @phase == :empty

          batch.find { |row| !@batch_done.includes?(row) }
        end

        # In the batch but not processed in this batch yet.
        private def queued?(row : Row) : Bool
          @phase != :select && batch.includes?(row) && !@batch_done.includes?(row) && row != current_row
        end

        private def busy_label : String
          @phase == :push ? "⟳ push…" : "⟳ bump…"
        end

        private def status_text(status : Symbol, message : String?) : String
          return "✗ échec : #{message}" if status == :fail

          STATUS_TEXT.fetch(status, "?")
        end

        private def group_start?(index : Int32) : Bool
          index.zero? || @rows[index].state != @rows[index - 1].state
        end

        private def progress_ratio : Float64
          @total.zero? ? 1.0 : @done / @total
        end

        private def config_failed? : Bool
          @config_status.try(&.[0]) == :fail
        end

        private def progress_title : String
          sum = summary
          "#{@phase == :push ? "Push" : "Bump"} #{@done}/#{@total} · ✓#{sum[:applied]} ✗#{sum[:failed]}#{config_suffix}"
        end

        # An apply that committed images then commits the root README, and
        # reports it only when that commit fails: a batch that returned
        # commits without such a report committed the README (or found it
        # unchanged).
        private def config_committed : Nil
          @config_failure = nil if @config_status.nil?
        end

        # The configuration repository has no line in the table: the title
        # names its failure while the batch runs, `config_alert` afterwards.
        private def config_suffix : String
          status = @config_status
          return "" unless status && status[0] == :fail

          " · #{config_failure_text(status[1])}"
        end

        private def config_failure_text(message : String?) : String
          "✗ dépôt de configuration : #{message}"
        end

        # Reminds that a push is waiting once bumps have been committed.
        private def push_hint : String
          count = applied.size
          count.zero? ? "" : "   ·   #{count} commit(s) à pousser (p)"
        end
      end
    end
  end
end
