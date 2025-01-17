require "./error"

module PlaceOS::Api::RunFrom
  Log = ::Log.for(PlaceOS::Api::RunFrom)
  record Result,
    status : Process::Status,
    output : IO::Memory

  def self.run_from(path, command, args, timeout : Time::Span = DEFAULT_TIMEOUT.seconds, **rest)
    # Run in a different thread to prevent blocking
    Log.info { {message: "Running command", path: path, command: command, args: args.to_s} }
    channel = Channel(Process::Status).new(capacity: 1)
    output = IO::Memory.new
    process = nil

    fiber = spawn(same_thread: true) do
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
    end

    Fiber.yield
    fiber.resume if fiber.running?

    select
    when status = channel.receive
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
