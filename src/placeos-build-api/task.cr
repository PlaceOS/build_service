require "uuid"
require "digest/crc32"
require "./utils"

module PlaceOS::Api
  @@tasks : Hash(String, Task) = {} of String => Task
  @@running : Hash(UInt32, String) = {} of UInt32 => String

  class_getter task_lock = Mutex.new

  def self.add_task(repository : String, branch : String, source_file : String, arch : String, commit : String? = nil,
                    username : String? = nil, password : String? = nil, force = false) : TaskStatus
    task_lock.synchronize do
      task = Task.new(repository, branch, source_file, arch, commit, username, password, force)
      csum = task.checksum
      if @@running.has_key?(csum)
        task = @@tasks[@@running[csum]]
      else
        @@running[csum] = task.id
        @@tasks[task.id] = task
        spawn { task.run }
      end
      task.status
    end
  end

  def self.task_status(id : String) : TaskStatus?
    task = task_lock.synchronize do
      val = @@tasks[id]?
      if (v = val) && (v.done?)
        @@running.delete(v.checksum)
        @@tasks.delete(v.id)
      end
      val
    end

    task.try &.status
  end

  record TaskStatus, state : State, id : String, message : String,
    driver : String, repo : String, branch : String, commit : String do
    include JSON::Serializable

    def success?
      @state == State::Done
    end

    def location
      uri = URI.encode_www_form(driver)
      params = URI::Params.build do |f|
        f.add "url", repo
        f.add "branch", branch
        f.add "commit", commit
      end
      "#{uri}?#{params}"
    end
  end

  enum State
    Pending
    Error
    Done

    def to_s(io : IO) : Nil
      io << (member_name || value.to_s).downcase
    end

    def to_s : String
      String.build { |io| to_s(io) }
    end
  end

  private class Task
    @state : State

    getter id : String
    getter repository : String
    getter branch : String
    getter source_file : String
    getter arch : String
    getter commit : String
    getter username : String?
    getter password : String?
    getter? force_compile : Bool

    def initialize(@repository, @branch, @source_file, @arch, @commit,
                   @username = nil, @password = nil, @force_compile = false)
      @id = UUID.random.to_s
      @state = State::Pending
      @message = "Driver #{source_file} compilation request accepted for processing"
    end

    def run
      if compile_required?
        @message = "Compiling driver #{source_file}"
        path, driver_binary = Api.compiler.compile(repository, branch, source_file, arch, commit, username, password)
        @message = "Compilation completed. Retrieving driver metadata"
        result = RunFrom.run_from(path, "./#{driver_binary}", {"-m"})
        raise Api::Error.new("Unable to retrieve metadata. #{result.output}") unless result.status.success?
        @message = "Metadata retrieval complete. Uploading driver to remote storage"
        driver_s3_name = Api.executable_name(repository, branch, source_file, arch, commit)
        meta_s3_name = Api.executable_name(repository, branch, source_file, "meta", commit)
        File.open(File.join(path, driver_binary)) do |driver|
          Api.with_s3(&.put(driver_s3_name, driver, meta_s3_name, result.output)).get_resp
        end
      end
      @state = State::Done
      @message = "Driver #{source_file} compilation completed"
    rescue ex : Exception
      @state = State::Error
      @message = ex.inspect_with_backtrace
    ensure
      path.try { |dir| FileUtils.rm_r(dir) } rescue nil
    end

    def compile_required?
      return true if force_compile?
      Api.with_s3 &.compiled?(source_file, arch, repository, commit, branch).nil?
    end

    def done?
      @state != State::Pending
    end

    def status
      TaskStatus.new(@state, id, @message, source_file, repository, branch, commit)
    end

    def checksum
      str = String.build do |sb|
        sb << repository
        sb << source_file
        sb << branch << commit << arch
      end
      Digest::CRC32.checksum(str.downcase)
    end
  end
end
