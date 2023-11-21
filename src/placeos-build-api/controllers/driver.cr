require "./application"
require "../task"
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
    @[AC::Route::GET("/:arch/compiled/:file_name")]
    def compiled(
      @[AC::Param::Info(description: "the system architecture, defaults to architecutre of system where this service is running", example: "amd64 | arm64")]
      arch : String,
      @[AC::Param::Info(name: "file_name", description: "the name of the driver file in the repository", example: "drivers/place/meet.cr")]
      file_name : String,
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

    # If requested driver is compiled and available in S3, returns 200 with defaults json
    # else returns 404
    @[AC::Route::GET("/defaults/:file_name")]
    def defaults(
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
        render json: ret.defaults
      else
        render :not_found
      end
    end

    # Async endpoint.
    # Upon receiving driver compilation request, it will return HTTP Status code 202 (Accepted) along with TaskStatus object, client should follow link provided in header field
    # Content-Location to track the status of this request.
    @[AC::Route::POST("/:arch/:file_name")]
    def build(
      @[AC::Param::Info(description: "the system architecture, defaults to architecutre of system where this service is running", example: "amd64 | arm64")]
      arch : String,
      @[AC::Param::Info(name: "file_name", description: "the name of the driver file in the repository", example: "drivers/place/meet.cr")]
      file_name : String,
      @[AC::Param::Info(description: "URL for a git repository", example: "https://github.com/placeOS/drivers")]
      url : String,
      @[AC::Param::Info(description: "Branch to return commits for, defaults to master", example: "main")]
      branch : String,
      @[AC::Param::Info(description: "the commit hash of the driver to check is compiled", example: "e901494")]
      commit : String,
      @[AC::Param::Info(description: "Whether to re-compile driver using the latest shards? default is false", example: "true")]
      force : Bool = false
    ) : TaskStatus
      Log.context.set(driver: file_name, arch: arch, repository: url, branch: branch, commit: commit, force: force)
      Log.info { "Building driver" }
      task = Api.add_task(url, branch, file_name, arch, commit, username, password, force)

      response.headers["Content-Location"] = Driver.task_status(arch: arch, id: task.id)
      render status: 202, json: task
    end

    # Returns the status of driver compilation request submitted via POST operation.
    # Still processing: Returns reponse code 200 (OK) and a TaskStatus object representing the status
    # Compilation completed: Returns response code 303 (See Other) and a Location header containing a URI of the resource to fetch compiled driver binary
    # Compilation Failure: Returns response code 200 (OK) and a TaskStatus object representing the status and failure message/reason.
    # Returns 404 if no such task exists
    @[AC::Route::GET("/:arch/task/:id")]
    def task_status(
      @[AC::Param::Info(description: "the system architecture, defaults to architecutre of system where this service is running", example: "amd64 | arm64")]
      arch : String,
      @[AC::Param::Info(description: "Submitted Job ID returned by POST request")]
      id : String
    ) : TaskStatus?
      if task = Api.task_status(id)
        if task.success?
          # Intentionally not using Driver.compiled method here, as that generates wrong url for driver.
          # driver contains path slashes and it need to be encoded via encode_www_form. So generating this URL manually
          response.headers["Location"] = "#{Driver::NAMESPACE[0]}/#{arch}/compiled/#{task.location}"
          render status: 303, json: task
        else
          render :ok, json: task
        end
      else
        render :not_found
      end
    end
  end
end
