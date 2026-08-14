require "./error"

module PlaceOS::Api::RunFrom
  Log = ::Log.for(PlaceOS::Api::RunFrom)
  record Result,
    status : Process::Status,
    output : IO::Memory

  def self.run_from(path, command, args, timeout : Time::Span = DEFAULT_TIMEOUT.seconds, **rest)
    # Run in a different thread to prevent blocking
    Log.info { {message: "Running command", path: path, command: command, args: args.to_s} }
    channel = Channel(Process::Status | Exception).new(capacity: 1)
    output = IO::Memory.new
    process = nil

    # NOTE: must be a plain `spawn` (not `same_thread: true`), and the fiber must
    # not be manually resumed. Since Crystal 1.21 the default runtime is the
    # `Fiber::ExecutionContext::Parallel` scheduler, whose `#spawn` raises on
    # `same_thread: true` — which failed every driver compile.
    spawn do
      begin
        process = Process.new(
          command,
          **rest,
          args: args,
          input: Process::Redirect::Close,
          output: output,
          error: output,
          chdir: path,
        )

        status = process.as(Process).wait
        channel.send(status) unless channel.closed?
      rescue e
        # Surface launch failures (missing binary, chdir errors, EMFILE on
        # pipe()) immediately rather than making the caller wait out `timeout`.
        channel.send(e) rescue nil
      end
    end

    select
    when result = channel.receive
      raise PlaceOS::Api::Error.new("Failed to launch #{command}: #{result.class}: #{result.message}\n#{output}") if result.is_a?(Exception)
      status = result
    when timeout(timeout)
      channel.close
      begin
        process.try(&.terminate)
      rescue RuntimeError
        # Ignore missing process
      end

      raise PlaceOS::Api::Error.new("Running #{command} timed out after #{timeout.total_seconds}s with:\n#{output}")
    end

    Result.new(status, output)
  end
end
