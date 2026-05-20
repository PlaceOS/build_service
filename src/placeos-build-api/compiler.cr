require "./utils"
require "./run_from"

module PlaceOS::Api
  def self.compiler
    Compiler::INSTANCE
  end

  private class Compiler
    INSTANCE = new
    Log      = ::Log.for(self)

    # Linker flags for compiled driver binaries, tuned to produce fully
    # symbolized stack traces on static-musl Alpine builds.
    #
    #   -no-pie / -Wl,-no-pie
    #     Build a non-PIE binary. Modern toolchains (gcc 15 on Alpine) often
    #     default to producing static-PIE binaries, which load at a random
    #     base address. On static musl, `dl_iterate_phdr` doesn't reliably
    #     report that base, so Crystal's DWARF self-decoder ends up adding
    #     the wrong (or zero) base to DWARF's low_pc/high_pc ranges and
    #     every `decode_function_name(pc)` lookup misses -> "???".
    #     Building non-PIE puts code at fixed absolute addresses that match
    #     DWARF's recorded addresses exactly, sidestepping the issue.
    #
    #   -Wl,--eh-frame-hdr
    #     Builds the .eh_frame_hdr section so the unwinder can find frame
    #     descriptors via a binary-searchable index.
    #
    #   -lunwind  (followed by -llzma)
    #     Place libunwind ahead of the toolchain's default unwinder
    #     (libgcc_eh) so Crystal's `LibUnwind._Unwind_Backtrace` resolves
    #     to nongnu libunwind, which actually works on static musl. Without
    #     this, libgcc_eh's unwinder is used and produces "???" for every
    #     frame on static Alpine builds (crystal-lang/crystal#4276).
    #
    #     Alpine's libunwind 1.8.1 is built with liblzma support (for
    #     decoding compressed minidebuginfo) and the unwind path pulls in
    #     ELF helper objects that reference `lzma_*`. So we link -llzma
    #     after -lunwind to satisfy those.
    #
    #   -rdynamic / -Wl,--export-dynamic
    #     Adds all symbols (not just used ones) to the dynamic symbol
    #     table. On a static binary, `dladdr` walks this table to map an
    #     IP back to a function name. Without it, even a working unwinder
    #     yields IPs that can't be named.
    #
    #   -Wl,--build-id
    #     Embeds a build-id so the binary's own DWARF lookup (used by
    #     Crystal when the :debug flag is set) can locate the right
    #     debug section.
    DRIVER_LINK_FLAGS = "-no-pie -Wl,-no-pie " \
                        "-Wl,--eh-frame-hdr -Wl,--build-id " \
                        "-rdynamic -Wl,--export-dynamic " \
                        "-lunwind -llzma"

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
          # Build for clear, fully-symbolized stack traces:
          #   --debug                    emit DWARF debug info
          #   --frame-pointers always    keep frame pointers (no -fomit-frame-pointer at any opt level)
          #   -O1                        light optimization; preserves frames so backtraces don't collapse to "???"
          #                              (--release is intentionally avoided: it enables -O3 + --single-module
          #                               which inlines aggressively and destroys backtrace fidelity)
          # See DRIVER_LINK_FLAGS for the rationale behind the linker flags.
          result = RunFrom.run_from(path,
            "crystal",
            {
              "build",
              "--debug",
              "--error-trace",
              "--no-color",
              "--static",
              "-O1",
              "--frame-pointers", "always",
              "--link-flags", DRIVER_LINK_FLAGS,
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
