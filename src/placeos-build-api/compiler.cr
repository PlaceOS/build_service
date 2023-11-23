require "./utils"
require "./run_from"

module PlaceOS::Api
  def self.compiler
    Compiler::INSTANCE
  end

  private class Compiler
    INSTANCE = new
    Log      = ::Log.for(self)
    private getter compile_lock = Mutex.new
    private getter compiling = Hash(String, Array(Channel(Nil))).new

    private def initialize
    end

    def compile(repository : String, branch : String, source_file : String, arch : String, commit : String? = nil,
                username : String? = nil, password : String? = nil)
      if (hash = commit) && hash.starts_with?(RECOMPILE_PREFIX)
        commit = hash.lchop(RECOMPILE_PREFIX)
      end

      Api.with_repository(repository, branch, source_file, commit, username, password) do |repo_path|
        _compile(repo_path.path, source_file, arch, (commit || repo_path.commit.hash))
      end
    rescue e : GitRepository::Error
      Log.error { e }
      raise Api::Error::Unauthorized.new(e.message || "")
    rescue ex
      unless ex.is_a?(Api::Error)
        Log.error { ex }
        raise Api::Error.new(ex.message || "")
      end
      raise ex
    end

    private def _compile(repository_path : Path, driver_file : String, arch : String, commit : String)
      path = repository_path.to_s
      install_shards(path)
      driver_binary = Api.executable_name(driver_file, arch, commit)
      comp_path = File.tempname
      Dir.mkdir_p(comp_path)
      binary_path = File.join(comp_path, driver_binary)
      build_script = File.join(path, "src/build.cr")
      raise Api::Error::CompileError.new("Driver file '#{driver_file}' not found") unless File.exists?(File.join(path, driver_file))

      wait_for_compilation(driver_binary) do
        ::Log.with_context(driver: driver_file, arch: arch, commit: commit) do
          start = Time.utc
          Log.info { "compiling #{driver_file}" }
          result = RunFrom.run_from(path,
            "crystal",
            {
              "build",
              "--error-trace",
              "--no-color",
              "--static",
              "--release",
              "-o", binary_path,
              build_script,
            },
            env: {"COMPILE_DRIVER" => driver_file})
          Log.info { "compiling #{driver_file} took #{(Time.utc - start).total_seconds}s" }
          unless result.status.success?
            output = result.output.to_s
            Log.debug { "build failed with #{output}" }
            raise Api::Error::CompileError.new(output)
          end

          {comp_path, driver_binary}
        end
      end
    end

    private def install_shards(repository_path : String)
      Log.info { "Checking shards" }
      result = RunFrom.run_from(repository_path, "shards", {"--no-color", "check", "--ignore-crystal-version", "--production"})
      output = result.output.to_s
      return if result.status.success? || output.includes?("Dependencies are satisfied")

      # Otherwise install shards
      Log.info { "Installing shards" }
      result = RunFrom.run_from(repository_path, "shards", {"--no-color", "install", "--ignore-crystal-version", "--production"})
      raise Api::Error::CompileError.new(result.output.to_s) unless result.status.success?
    end

    private def wait_for_compilation(executable : String, &)
      block_compilation(executable)
      yield
    ensure
      unblock_compilation(executable)
    end

    # Blocks if compilation for the executable is in progress
    private def block_compilation(executable : String)
      channel = nil
      compile_lock.synchronize do
        if compiling.has_key? executable
          channel = Channel(Nil).new
          compiling[executable] << channel
        else
          compiling[executable] = [] of Channel(Nil)
        end
      end

      if channel
        channel.receive?
        block_compilation(executable)
      end
    end

    private def unblock_compilation(executable : String)
      compile_lock.synchronize do
        if waiting = compiling.delete(executable)
          waiting.each &.send(nil)
        end
      end
    end
  end
end
