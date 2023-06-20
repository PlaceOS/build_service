require "action-controller/logger"

module PlaceOS::Api
  APP_NAME    = "build-api"
  API_VERSION = "v1"

  VERSION      = {{ system(%(shards version "#{__DIR__}")).chomp.stringify.downcase }}
  BUILD_TIME   = {{ system("date -u").stringify }}
  BUILD_COMMIT = {{ env("PLACE_COMMIT") || "DEV" }}

  AWS_REGION         = ENV["AWS_REGION"]?.presence || abort("AWS_REGION not in environment")
  AWS_KEY            = ENV["AWS_KEY"]?.presence || abort("AWS_KEY not in environment")
  AWS_SECRET         = ENV["AWS_SECRET"]?.presence || abort("AWS_SECRET not in environment")
  AWS_S3_BUCKET      = ENV["AWS_S3_BUCKET"]?.presence || abort("AWS_S3_BUCKET not in environment")
  AWS_S3_ENDPOINT    = ENV["AWS_S3_ENDPOINT"]?
  AWS_S3_LINK_EXPIRY = ENV["AWS_S3_LINK_EXPIRY"]?.try &.to_i.minutes || 5.minutes

  ENVIRONMENT   = ENV["SG_ENV"]? || "development"
  IS_PRODUCTION = ENVIRONMENT == "production"

  DEFAULT_PORT          = (ENV["SG_SERVER_PORT"]? || 3000).to_i
  DEFAULT_HOST          = ENV["SG_SERVER_HOST"]? || "127.0.0.1"
  DEFAULT_PROCESS_COUNT = (ENV["SG_PROCESS_COUNT"]? || 1).to_i

  DEFAULT_TIMEOUT = (ENV["TIMEOUT"]? || 120).to_i

  def self.arch
    {% if flag?(:x86_64) %} "amd64" {% elsif flag?(:aarch64) %} "arm64" {% end %} || raise("Uknown architecture")
  end
end
