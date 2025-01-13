require "git-repository"
require "file_utils"
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

    Log.info { "Downloading #{uri} at #{branch}" }
    commit = repo.fetch_commit(branch, commit, source_file, temporary_path)

    Log.trace { {message: "checked out repository", branch: branch, hash: commit.hash} }
    yield Repository.new(Path[temporary_path], commit)
  ensure
    temporary_path.try { |dir| FileUtils.rm_r(dir) } rescue nil
  end

  record Repository, path : Path, commit : GitRepository::Commit
end
