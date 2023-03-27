require "git-repository"
require "file_utils"
require "opentelemetry-sdk"
require "./compiler"

module PlaceOS::Api
  def self.build_driver(repository : String, branch : String, source_file : String, arch : String, commit : String? = nil,
                        username : String? = nil, password : String? = nil)
    path, driver_binary = compiler.compile(repository, branch, source_file, arch, commit, username, password)
    result = RunFrom.run_from(path, "./#{driver_binary}", {"-m"})
    raise Api::Error.new("Unable to retrieve metadata. #{result.output}") unless result.status.success?
    driver_s3_name = executable_name(repository, branch, source_file, arch, commit)
    meta_s3_name = executable_name(repository, branch, source_file, "meta", commit)
    File.open(File.join(path, driver_binary)) do |driver|
      with_s3(&.put(driver_s3_name, driver, meta_s3_name, result.output)).get_resp
    end
  ensure
    path.try { |dir| FileUtils.rm_r(dir) } rescue nil
  end

  # Generate driver binary name
  def self.executable_name(driver_source, arch, commit)
    driver_source = driver_source.rchop(".cr").gsub(/\/|\./, "_")
    commit = commit[..6] if commit.size > 6
    {driver_source, commit, arch}.join("_").downcase
  end

  # Generate driver binary name for S3
  def self.executable_name(repo_uri, branch, driver_source, arch, commit)
    repo_uri = repo_uri.lchop("https://").lchop("http://").rchop(".git").downcase
    repo_uri = "#{repo_uri}/" unless repo_uri[-1] == '/'
    "#{repo_uri}#{branch}/#{executable_name(driver_source, arch, commit)}"
  end

  def self.repository(uri : String, branch : String? = nil, username : String? = nil, password : String? = nil)
    GitRepository.new(uri, branch: branch, username: username, password: password)
  end

  def self.with_repository(
    uri : String, branch : String, source_file : String, commit : String?, username : String?, password : String?, & : Repository ->
  )
    Log.trace { {message: "checking out repository", branch: branch} }
    temporary_path = File.tempname(source_file.rchop(".cr").gsub(/\/|\./, "_"))

    repo = repository(uri, branch, username, password)
    commit = "FETCH_HEAD" if commit.nil?

    commit = OpenTelemetry.trace.in_span("Downloading #{uri} at #{branch}") do
      repo.fetch_commit(branch, commit, source_file, temporary_path)
    end

    Log.trace { {message: "checked out repository", branch: branch, hash: commit.hash} }
    yield Repository.new(Path[temporary_path], commit)
  ensure
    temporary_path.try { |dir| FileUtils.rm_r(dir) } rescue nil
  end

  record Repository, path : Path, commit : GitRepository::Commit

  private class Timer
    def initialize(@when : Time, &block)
      @channel = Channel(Nil).new(1)
      @completed = false
      @cancelled = false

      spawn do
        loop do
          sleep({Time::Span.zero, @when - Time.utc}.max)
          break if @completed || @cancelled
          next if Time.utc < @when
          break @channel.send(nil)
        end
      end

      spawn do
        @channel.receive

        unless @cancelled
          @completed = true
          block.call
        end
      end
    end

    def self.new(when : Time::Span, &block)
      new(Time.utc + when, &block)
    end

    def cancel
      return if @completed || @cancelled
      @cancelled = true
      @channel.send(nil)
    end
  end
end

class GitRepository::Generic
  def fetch_commit(branch : String, commit : String, source_file : String, download_to_path : String | Path) : Commit
    download_to = download_to_path.to_s

    # download the commit
    create_temp_folder do |temp_folder|
      git = Commands.new(temp_folder)
      git.init
      git.add_origin @repository
      git.fetch_all branch             # git fetch origin branch
      git.checkout branch              # git checkout branch or FETCH_HEAD
      git.checkout commit, source_file # git checkout FETCH_HEAD or sha1 -- source_file

      move_into_place(temp_folder, download_to)

      # grab the current commit hash
      git.path = download_to
      git.commits(depth: 1).first
    end
  end
end

struct GitRepository::Commands
  def fetch_all(branch : String)
    run_git("fetch", {"origin", branch})
  end

  def checkout(branch : String, file : String)
    run_git("checkout", {branch, "--", file})
  end
end
