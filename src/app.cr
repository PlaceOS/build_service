require "option_parser"
require "./constants"
require "./two_factor"

# Server defaults
port = PlaceOS::Api::DEFAULT_PORT
host = PlaceOS::Api::DEFAULT_HOST
process_count = PlaceOS::Api::DEFAULT_PROCESS_COUNT
exit_code = nil

# Command line options
OptionParser.parse(ARGV.dup) do |parser|
  parser.banner = "Usage: #{PlaceOS::Api::APP_NAME} [arguments]"

  parser.on("-b HOST", "--bind=HOST", "Specifies the server host") { |h| host = h }
  parser.on("-p PORT", "--port=PORT", "Specifies the server port") { |p| port = p.to_i }

  parser.on("-w COUNT", "--workers=COUNT", "Specifies the number of processes to handle requests") do |w|
    process_count = w.to_i
  end

  parser.on("-r", "--routes", "List the application routes") do
    ActionController::Server.print_routes
    exit 0
  end

  parser.on("-v", "--version", "Display the application version") do
    puts "#{PlaceOS::Api::APP_NAME} v#{PlaceOS::Api::VERSION}"
    exit 0
  end

  parser.on("-i ID", "--2fa=ID", "generates the 2fa QR code with the specified identifier") do |id|
    secret = ENV["TOTP_SECRET"]?
    if secret
      TwoFactor.print_totp_qr_code(id, secret)
    else
      puts "must configure 'TOTP_SECRET' ENV var"
    end
    exit 0
  end

  parser.on("-t", "--totp", "generates a totp secret") do
    puts "export TOTP_SECRET=#{TOTP.generate_base32_secret(32)}"
    exit 0
  end

  parser.on("-a", "--access", "generates a valid authorisation header") do
    secret = ENV["TOTP_SECRET"]?
    if secret
      code = TOTP.generate_number_string(secret)
      puts "Current code: #{code}"
      puts "Authorization: Basic #{Base64.strict_encode(":#{code}")}"
    else
      puts "must configure 'TOTP_SECRET' ENV var"
    end
    exit 0
  end

  parser.on("-c URL", "--curl=URL", "Perform a basic health check by requesting the URL") do |url|
    begin
      response = HTTP::Client.get url
      exit 0 if (200..499).includes? response.status_code
      puts "health check failed, received response code #{response.status_code}"
      exit 1
    rescue error
      error.inspect_with_backtrace(STDOUT)
      exit 2
    end
  end

  parser.on("-d", "--docs", "Outputs OpenAPI documentation for this service") do
    docs = ActionController::OpenAPI.generate_open_api_docs(
      title: PlaceOS::Api::APP_NAME,
      version: PlaceOS::Api::VERSION,
      description: "PlaceOS Build API. Performs driver compilation, retrieval and storage on S3"
    ).to_yaml

    parser.on("-f FILE", "--file=FILE", "Save the docs to a file") do |file|
      File.write(file, docs)
    end

    puts docs
    exit_code = 0
  end

  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit 0
  end
end

if exit_code
  exit exit_code.as(Int32)
end

# Load the routes
PlaceOS::Api::Log.info { "Launching #{PlaceOS::Api::APP_NAME} v#{PlaceOS::Api::VERSION}" }

# Requiring config here ensures that the option parser runs before
# attempting to connect to databases etc.
require "./config"
server = ActionController::Server.new(port, host)

# (process_count < 1) == `System.cpu_count` but this is not always accurate
# Clustering using processes, there is no forking once crystal threads drop
server.cluster(process_count, "-w", "--workers") if process_count != 1

terminate = Proc(Signal, Nil).new do |signal|
  puts " > terminating gracefully"
  spawn { server.close }
  signal.ignore
end

# Detect ctr-c to shutdown gracefully
# Docker containers use the term signal
Signal::INT.trap &terminate
Signal::TERM.trap &terminate

# Start the Task Runner
PlaceOS::Api.on_start

# Start the server
server.run do
  PlaceOS::Api::Log.info { "Listening on #{server.print_addresses}" }
end

# Shutdown message
PlaceOS::Api::Log.info { "#{PlaceOS::Api::APP_NAME} leaps through the veldt\n" }
