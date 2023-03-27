require "./application"
require "../s3"

module PlaceOS::Api
  class Driver < Application
    base "/api/build/v1"

    @[AC::Route::GET("/")]
    def index
      # Just for health-check purposes
      render json: {health: "ok"}
    end

    # returns the build details of the service
    @[AC::Route::GET("/version")]
    def version : NamedTuple(version: String, build_time: String, commit: String, service: String)
      render json: {
        version:    VERSION,
        build_time: BUILD_TIME,
        commit:     BUILD_COMMIT,
        service:    APP_NAME,
      }
    end

    # If requested driver is compiled and available in S3, returns 200 with json response with size, md5, modified-time, pre-signed url details
    # else returns 404
    @[AC::Route::GET("/compiled/:file_name/:arch")]
    def compiled(
      @[AC::Param::Info(name: "file_name", description: "the name of the driver file in the repository", example: "drivers/place/meet.cr")]
      file_name : String,
      @[AC::Param::Info(description: "the system architecture, defaults to architecutre of system where this service is running", example: "amd64 | arm64")]
      arch : String,
      @[AC::Param::Info(description: "URL for a git repository", example: "https://github.com/placeOS/drivers")]
      url : String,
      @[AC::Param::Info(description: "Branch to return driver binary for, defaults to master", example: "main")]
      branch : String?,
      @[AC::Param::Info(description: "the commit hash of the driver to check is compiled", example: "e901494")]
      commit : String
    ) : S3::LinkData?
      Log.context.set(driver: file_name, arch: arch, repository: url, branch: branch, commit: commit)
      if ret = Api.with_s3 &.compiled?(file_name, arch, url, commit, branch)
        ret.get_resp
      else
        render :not_found
      end
    end

    # If requested driver is compiled and available in S3, returns 200 with metadata json
    # else returns 404
    @[AC::Route::GET("/metadata/:file_name")]
    def metadata(
      @[AC::Param::Info(name: "file_name", description: "the name of the driver file in the repository", example: "drivers/place/meet.cr")]
      file_name : String,
      @[AC::Param::Info(description: "URL for a git repository", example: "https://github.com/placeOS/drivers")]
      url : String,
      @[AC::Param::Info(description: "Branch to return driver binary for, defaults to master", example: "main")]
      branch : String?,
      @[AC::Param::Info(description: "the commit hash of the driver to check is compiled, defaults to latest commit on branch", example: "e901494362f6859100b8f3")]
      commit : String
    ) : String?
      Log.context.set(driver: file_name, repository: url, branch: branch, commit: commit)
      if ret = Api.with_s3 &.compiled?(file_name, "meta", url, commit, branch)
        render json: ret.metadata
      else
        render :not_found
      end
    end

    # Compile requested driver if not already compiled (or force = true), pushes compiled driver binary to S3, returns 200 with json response with size, md5, modified-time, pre-signed url details.
    # Returns 401 if repository authentication or git checkout failed
    # Returns 406 with build stack-trace on compilation failure
    @[AC::Route::POST("/:file_name/:arch")]
    def build(
      @[AC::Param::Info(name: "file_name", description: "the name of the driver file in the repository", example: "drivers/place/meet.cr")]
      file_name : String,
      @[AC::Param::Info(description: "the system architecture, defaults to architecutre of system where this service is running", example: "amd64 | arm64")]
      arch : String,
      @[AC::Param::Info(description: "URL for a git repository", example: "https://github.com/placeOS/drivers")]
      url : String,
      @[AC::Param::Info(description: "Branch to return commits for, defaults to master", example: "main")]
      branch : String,
      @[AC::Param::Info(description: "the commit hash of the driver to check is compiled", example: "e901494")]
      commit : String,
      @[AC::Param::Info(description: "Whether to re-compile driver using the latest shards? default is false", example: "true")]
      force : Bool = false
    ) : S3::LinkData?
      Log.context.set(driver: file_name, arch: arch, repository: url, branch: branch, commit: commit, force: force)
      if !force && (ret = Api.with_s3 &.compiled?(file_name, arch, url, commit, branch))
        render json: ret.get_resp
      else
        Log.info { "Building driver" }
        render json: Api.build_driver(url, branch, file_name, arch, commit, username, password)
      end
    end
  end
end
