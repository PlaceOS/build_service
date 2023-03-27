# Application dependencies
require "action-controller"

# Application code
require "./logging"
require "./placeos-build-api"
require "./telemetry"

# Server required after application controllers
require "action-controller/server"

module PlaceOS::Api
  # Filter out sensitive params that shouldn't be logged
  filters = ["bearer_token", "secret", "password", "api-key"]

  # Add handlers that should run before your application
  ActionController::Server.before(
    ActionController::ErrorHandler.new(Api.running_in_production?, ["X-Request-ID"]),
    ActionController::ErrorHandler.new,
    ActionController::LogHandler.new(filters, ms: true)
  )
end
