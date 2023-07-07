require "action-controller"
require "uuid"

require "../error"
require "../utils"

module PlaceOS::Api
  abstract class Application < ActionController::Base
    macro inherited
      Log = ::PlaceOS::Api::Log.for({{ @type }})
    end

    # Headers
    ###########################################################################

    getter username : String? { request.headers["X-Git-Username"]?.presence }
    getter password : String? { request.headers["X-Git-Password"]?.presence }
    getter token : String? { request.headers["X-Git-Token"]?.presence }

    ###########################################################################

    # Renders API error messages in a consistent format
    def render_error(status : HTTP::Status, message : String?, **additional)
      message = "API error" if message.nil?
      render status: status, json: additional.merge({message: message})
    end

    getter request_id : String do
      request.headers["X-Request-ID"]? || UUID.random.to_s
    end

    # This makes it simple to match client requests with server side logs.
    # When building microservices this ID should be propagated to upstream services.
    @[AC::Route::Filter(:before_action)]
    def set_request_id
      Log.context.set(
        client_ip: client_ip,
        request_id: request_id
      )
      response.headers["X-Request-ID"] = request_id
    end

    @[AC::Route::Filter(:before_action)]
    def set_date_header
      response.headers["Date"] = HTTP.format_time(Time.utc)
    end

    @[AC::Route::Filter(:before_action, except: [:index, :version, :task_status])]
    def get_default_branch(url : String, branch : String?, arch : String?, commit : String?)
      params["arch"] = Api.arch unless arch.presence
      if branch.nil? || commit.nil?
        repo = Api.repository(url, branch, username, password)
        params["branch"] = repo.default_branch if branch.nil?
        params["commit"] = repo.commits(params["branch"], depth: 1).first.hash if commit.nil?
      end
    end

    ###########################################################################
    # Error Handlers
    ###########################################################################

    struct CommonError
      include JSON::Serializable

      getter error : String?
      getter backtrace : Array(String)?

      def initialize(error, backtrace = true)
        @error = error.message
        @backtrace = backtrace ? error.backtrace : nil
      end
    end

    # 401 if credentials are invalid
    @[AC::Route::Exception(Error::Unauthorized, status_code: HTTP::Status::UNAUTHORIZED)]
    def invalid_access_credentials(error) : CommonError
      Log.debug { error.message }
      CommonError.new(error, false)
    end

    # 404 if resource not present
    @[AC::Route::Exception(Error::NotFound, status_code: HTTP::Status::NOT_FOUND)]
    def resource_not_found(error) : CommonError
      Log.debug(exception: error) { error.message }
      CommonError.new(error, false)
    end

    # 406 if compiler error
    @[AC::Route::Exception(Error::CompileError, status_code: HTTP::Status::NOT_ACCEPTABLE)]
    def compile_error(error) : CommonError
      Log.debug(exception: error) { error.message }
      CommonError.new(error, false)
    end

    # ========================
    # Action Controller Errors
    # ========================

    # Provides details on available data formats
    struct ContentError
      include JSON::Serializable
      include YAML::Serializable

      getter error : String
      getter accepts : Array(String)? = nil

      def initialize(@error, @accepts = nil)
      end
    end

    # covers no acceptable response format and not an acceptable post format
    # @[AC::Route::Exception(AC::Route::NotAcceptable, status_code: HTTP::Status::NOT_ACCEPTABLE)]
    @[AC::Route::Exception(AC::Route::UnsupportedMediaType, status_code: HTTP::Status::UNSUPPORTED_MEDIA_TYPE)]
    def bad_media_type(error) : ContentError
      ContentError.new error: error.message.not_nil!, accepts: error.accepts
    end

    # Provides details on which parameter is missing or invalid
    struct ParameterError
      include JSON::Serializable
      include YAML::Serializable

      getter error : String
      getter parameter : String? = nil
      getter restriction : String? = nil

      def initialize(@error, @parameter = nil, @restriction = nil)
      end
    end

    # handles paramater missing or a bad paramater value / format
    @[AC::Route::Exception(AC::Route::Param::MissingError, status_code: HTTP::Status::UNPROCESSABLE_ENTITY)]
    @[AC::Route::Exception(AC::Route::Param::ValueError, status_code: HTTP::Status::BAD_REQUEST)]
    def invalid_param(error) : ParameterError
      ParameterError.new error: error.message.not_nil!, parameter: error.parameter, restriction: error.restriction
    end
  end
end
