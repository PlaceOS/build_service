require "./application"
require "../task"

module PlaceOS::Api
  class Monitor < Application
    base "/api/build/v1"

    # Job monitor endpoint. Provides a list of requested state Jobs
    @[AC::Route::GET("/monitor")]
    def monitor(
      @[AC::Param::Info(name: "state", description: "state of job to return. One of [pending,running,cancelled error,done]. Defaults to 'pending'", example: "pending")]
      state : Api::State = Api::State::Pending,
    ) : Array(TaskStatus)
      render json: Api.get_job_queue(state)
    end

    @[AC::Route::DELETE("/cancel/:job")]
    def cancel(
      @[AC::Param::Info(name: "job", description: "ID of previously submitted compilation job")]
      job : String,
    ) : String?
      if Api.cancel_task(job)
        render json: {status: "success", message: "Job with id #{job} cancelled successfully"}.to_json
      elsif Api.running?(job)
        render status: 409, json: {status: "error", message: "Can not cancel already running job."}.to_json
      else
        render :not_found
      end
    end
  end
end
