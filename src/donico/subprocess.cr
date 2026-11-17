module Donico
  # Runs child processes whose stdout and stderr are read back as one text.
  module Subprocess
    # Runs `command` and returns its status with stdout and stderr merged, in
    # the order the child wrote them. `started` receives the live Process
    # right after the spawn, so a caller can signal it while this call waits.
    #
    # The child gets one pipe as both streams and this fiber is its only
    # reader. Handing one IO::Memory to `Process.run` as `output:` and `error:`
    # instead makes the stdlib copy each stream from its own fiber: under
    # -Dpreview_mt, two threads then write the same unsynchronized buffer,
    # which loses bytes, spins forever or aborts in the GC.
    #
    # Raises File::NotFoundError when the command or `chdir` does not exist.
    def self.run(command : String, args : Array(String), *, chdir : String? = nil,
                 env : Hash(String, String)? = nil, clear_env : Bool = false,
                 started : Proc(Process, Nil)? = nil) : {Process::Status, String}
      reader, writer = IO.pipe
      begin
        process = Process.new(command, args, chdir: chdir, env: env, clear_env: clear_env,
          input: Process::Redirect::Close, output: writer, error: writer)
        # Before the ensure below and before the first read: the earliest
        # point at which the caller can learn of the child.
        started.try(&.call(process))
      ensure
        # The child holds its own copy: with ours open, the pipe never ends.
        writer.close
      end
      text = reader.gets_to_end
      {process.wait, text}
    ensure
      reader.try(&.close)
    end
  end
end
