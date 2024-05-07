require "action-controller/logger"
require "./two_factor"

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

  DEFAULT_TIMEOUT  = (ENV["TIMEOUT"]? || 300).to_i
  RECOMPILE_PREFIX = "RECOMPILE-"

  PARALELL_JOBS           = (ENV["PARALELL_JOBS"]? || 1).to_i
  ALLOWED_FAILED_ATTEMPTS = (ENV["ALLOWED_FAILED_ATTEMPTS"]? || 2).to_i

  # security
  TOTP_SECRET           = ENV["TOTP_SECRET"]? || TOTP.generate_base32_secret(32)
  COOKIE_SESSION_KEY    = ENV["COOKIE_SESSION_KEY"]? || "_spider_gazelle_"
  COOKIE_SESSION_SECRET = ENV["COOKIE_SESSION_SECRET"]? || TOTP_SECRET

  def self.arch
    {% if flag?(:x86_64) %} "amd64" {% elsif flag?(:aarch64) %} "arm64" {% end %} || raise("Uknown architecture")
  end
end
