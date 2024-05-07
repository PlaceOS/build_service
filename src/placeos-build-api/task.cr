require "uuid"
require "digest/crc32"
require "deque"
require "./utils"
require "./persistence"

module PlaceOS::Api
  class_getter task_runner = TaskRunner.new(PARALELL_JOBS)
  class_getter task_lock = Mutex.new

  def self.on_start
    task_runner.start
    Api.get_incomplete_tasks.each do |task|
      case task.state
      when .pending? then task_runner.add_task(task)
      when .running? then Api.update_status(task.id, State::Cancelled, "Job cancelled due to process kill")
      end
    end
  end

  def self.add_task(repository : String, branch : String, source_file : String, arch : String, commit : String,
                    username : String? = nil, password : String? = nil, force = false) : TaskStatus
    task_lock.synchronize do
      csum = checksum(repository, source_file, branch, commit, arch)
      if Api.attempts(csum, State::Error) >= ALLOWED_FAILED_ATTEMPTS
        Log.info { {message: "Driver compilation failure attempts exceed, returning last failed reason", driver: source_file, branch: branch, commit: commit} }
        return get_last_result(csum)
      end
      if Api.job_exists?(csum)
        job = Api.get_last_result(csum)
        return job if running?(job.id)
      end
      task = Task.new(repository, branch, source_file, arch, commit, username, password, force)
      Api.add_job(task)

      task_runner.add_task(task)
      task.status
    end
  end

  def self.cancel_task(task_id : String)
    return false unless running?(task_id, true)
    task_runner.cancel_task(task_id)
    Api.update_status(task_id, State::Cancelled, "Job cancelled by admin")
    true
  end

  def self.task_status(id : String) : TaskStatus?
    task_lock.synchronize do
      get_status(id)
    end
  end

  def self.running?(id : String, pending_only = false)
    task_runner.has?(id, pending_only)
  end

  def self.checksum(repository, source_file, branch, commit, arch)
    str = String.build do |sb|
      sb << repository
      sb << source_file
      sb << branch << commit << arch
    end
    Digest::CRC32.checksum(str.downcase)
  end

  record TaskStatus, state : State, id : String, message : String,
    driver : String, repo : String, branch : String, commit : String, timestamp : Time do
    include JSON::Serializable
    include DB::Serializable

    @[DB::Field(key: "sha")]
    @commit : String

    @[DB::Field(key: "source")]
    @driver : String

    @[DB::Field(key: "updated_at")]
    @timestamp : Time

    @[DB::Field(converter: Enum::ValueConverter(PlaceOS::Api::State))]
    @state : State

    def success?
      @state == State::Done
    end

    def cancelled?
      @state == State::Cancelled
    end

    def pending?
      @state == State::Pending
    end

    def completed?
      @state.in?(State::Cancelled, State::Error, State::Done)
    end

    def in_progress?
      @state.in?(State::Pending, State::Running)
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

    def_equals_and_hash @state, @id, @message, @driver, @repo, @branch, @commit
  end

  enum State
    Pending
    Running
    Cancelled
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
    include DB::Serializable
    Log = ::Log.for(self)

    @[DB::Field(converter: Enum::ValueConverter(PlaceOS::Api::State))]
    getter state : State

    getter id : String
    @[DB::Field(key: "repo")]
    getter repository : String
    getter branch : String
    @[DB::Field(key: "source")]
    getter source_file : String
    getter arch : String
    @[DB::Field(key: "sha")]
    getter commit : String
    getter username : String?
    getter password : String?
    @[DB::Field(key: "force")]
    getter? force_compile : Bool
    @[DB::Field(ignore: true)]
    @checksum : UInt32?

    def initialize(@repository, @branch, @source_file, @arch, @commit,
                   @username = nil, @password = nil, @force_compile = false)
      @id = UUID.random.to_s
      @state = State::Pending
      @message = "Driver #{source_file} compilation request accepted for processing"
    end

    def log(msg : String? = nil)
      Log.info { {message: msg || @message, id: id, repository: repository, branch: branch, source_file: source_file, commit: commit, force_compile: force_compile?} }
      update_status
    end

    def run
      if compile_required?
        @state = State::Running
        @message = "Compiling driver #{source_file}"
        log
        path, driver_binary = Api.compiler.compile(repository, branch, source_file, arch, commit, username, password)
        @message = "Compilation completed. Retrieving driver metadata & defaults"
        log
        meta = RunFrom.run_from(path, "./#{driver_binary}", {"-m"})
        raise Api::Error.new("Unable to retrieve metadata. #{meta.output}") unless meta.status.success?
        defaults = RunFrom.run_from(path, "./#{driver_binary}", {"-d"})
        raise Api::Error.new("Unable to retrieve defaults. #{defaults.output}") unless defaults.status.success?

        @message = "Metadata & defaults retrieval complete. Uploading driver to remote storage"
        log
        driver_s3_name = Api.executable_name(repository, branch, source_file, arch, commit)
        meta_s3_name = Api.executable_name(repository, branch, source_file, "meta", commit)
        defaults_s3_name = Api.executable_name(repository, branch, source_file, "defaults", commit)
        driver = IO::Memory.new
        File.open(File.join(path, driver_binary)) do |io|
          IO.copy(io, driver)
        end
        driver.rewind
        Api.with_s3(&.put(driver_s3_name, driver, meta_s3_name, meta.output, defaults_s3_name, defaults.output)).get_resp
      end
      @state = State::Done
      @message = "Driver #{source_file} compilation completed"
      log
    rescue ex : Exception
      @state = State::Error
      @message = ex.inspect_with_backtrace
      update_status
      Log.error(exception: ex) { "Exception occurred in Task run" }
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
      update_status
      TaskStatus.new(@state, id, @message, source_file, repository, branch, commit, Time.utc)
    end

    def checksum
      @checksum ||= begin
        str = String.build do |sb|
          sb << repository
          sb << source_file
          sb << branch << commit << arch
        end
        Digest::CRC32.checksum(str.downcase)
      end
    end

    def update_status
      Api.update_status(id, checksum, @state, @message)
    end
  end

  class TaskRunner
    WAIT_TIME = 5.second
    getter lock : Mutex
    getter tasks : Deque(Task)
    getter running : Array(String)

    def initialize(@job_count : Int32)
      @lock = Mutex.new
      @tasks = Deque(Task).new
      @job_queue = Channel(Task).new(@job_count)
      @running = Array(String).new
      @terminate_queue = Channel(Nil).new(@job_count)
      @stop_chan = Channel(Nil).new
    end

    def add_task(task : Task)
      lock.synchronize { tasks.push(task) }
    end

    def has?(task_id : String, pending_only = false) : Bool
      lock.synchronize {
        task = tasks.any? { |t| t.id == task_id }
        return task if pending_only
        task || running.includes?(task_id)
      }
    end

    def cancel_task(task_id : String) : Nil
      lock.synchronize { tasks.reject! { |t| t.id == task_id } }
    end

    def start
      @job_count.times do |i|
        spawn(name: "Worker-#{i + 1}") { handle_job(@job_queue, @terminate_queue, WAIT_TIME) }
      end
      spawn(name: "JobRunner") { run(@stop_chan) }
    end

    def stop
      spawn { @stop_chan.send(nil) }
    end

    def get_job?
      lock.synchronize do
        work = tasks.pop?
        if w = work
          running << w.id
        end
        work
      end
    end

    def job_done(id : String) : Nil
      lock.synchronize { running.delete(id) }
    end

    private def run(terminate : Channel(Nil))
      loop do
        if task = get_job?
          begin
            select
            when terminate.receive?
              Log.info { "JobRunner received shutdown request" }
              break
            when @job_queue.send(task)
              Log.info { {message: "Task scheduled to run by worker.", task: task.id, driver: task.source_file} }
              next
            end
          rescue Channel::ClosedError
            Log.error { "ERROR: Job runner queue channel closed" }
            break
          end
        end
        sleep 0.1
      end
      Log.info { "Terminating job workers" }
      @job_count.times { @terminate_queue.send(nil) }
    end

    private def handle_job(chan : Channel(Task), terminate : Channel(Nil), wait_time : Time::Span)
      loop do
        select
        when task = chan.receive
          task.run
          job_done(task.id)
        when terminate.receive?
          Log.info { "shutting down job worker" }
          break
        when timeout wait_time
          sleep 0.1
        end
      rescue Channel::ClosedError
        Log.error { "shutting down job worker #{Fiber.current.name} due to channel closed" }
        break
      end
    end
  end
end

module Enum::ValueConverter(T)
  def self.from_rs(rs : ::DB::ResultSet)
    val = rs.read(Int32?) || 0
    T.from_value(val)
  end
end
