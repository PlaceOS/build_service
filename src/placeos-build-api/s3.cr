require "awscr-s3"
require "http/headers"
require "./utils"

module PlaceOS::Api
  def self.with_s3(&)
    s3 = S3.new
    with s3 yield s3
  end

  # :nodoc:
  class S3
    getter client : Awscr::S3::Client
    @@cache = {} of String => DriverInfo

    def initialize
      @client = Awscr::S3::Client.new(AWS_REGION, AWS_KEY, AWS_SECRET, endpoint: AWS_S3_ENDPOINT)
    end

    def compiled?(driver, arch, repo, commit, branch)
      name = Api.executable_name(repo, branch, driver, arch, commit)
      @@cache.fetch(name) do |key|
        Log.info { "Driver not found in cache." }
        resp = head(key)
        @@cache[key] = DriverInfo.new(key, resp.headers)
      rescue ex
        Log.error { ex }
        nil
      end
    end

    def head(name)
      client.head_object(AWS_S3_BUCKET, name)
    end

    def get(name, &)
      client.get_object(AWS_S3_BUCKET, name) { |resp| yield resp.body_io }
    end

    def put(driver_name : String, binary : IO, meta_name : String, meta : IO)
      client.put_object(AWS_S3_BUCKET, object: driver_name, body: binary)
      resp = head(driver_name)
      dinfo = DriverInfo.new(driver_name, resp.headers)
      dinfo.set_metadata(meta.gets_to_end)
      @@cache[driver_name] = dinfo
      meta.rewind
      client.put_object(AWS_S3_BUCKET, object: meta_name, body: meta)
      dinfo
    end

    record LinkData, size : Int64, md5 : String, modified : Time, url : String, link_expiry : Time do
      include JSON::Serializable
      @[JSON::Field(converter: Time::EpochConverter)]
      getter modified : Time
      @[JSON::Field(converter: Time::EpochConverter)]
      getter link_expiry : Time
    end

    class DriverInfo
      include JSON::Serializable
      getter size : Int64
      getter md5 : String
      @[JSON::Field(converter: Time::EpochConverter)]
      getter modified : Time
      @metadata : String?

      def initialize(@name : String, headers : HTTP::Headers)
        @size = headers["content-length"].to_i64
        @md5 = headers["etag"].strip('"')
        @modified = Time::Format::RFC_2822.parse(headers["last-modified"])
      end

      def metadata : String
        @metadata ||= begin
          Api.with_s3 &.get("#{@name}", &.gets_to_end)
        rescue ex
          Log.error { ex }
          raise ex
        end
      end

      def url : String
        options = Awscr::S3::Presigned::Url::Options.new(
          aws_access_key: AWS_KEY,
          aws_secret_key: AWS_SECRET,
          region: AWS_REGION,
          object: "/#{@name}",
          bucket: AWS_S3_BUCKET,
          host_name: hostname,
          expires: AWS_S3_LINK_EXPIRY.to_i.to_i32,
          additional_options: {
            "Content-Type" => "binary/octet-stream",
          })
        url = Awscr::S3::Presigned::Url.new(options)
        Log.debug { "Generating signed URL}" }
        url.for(:get)
      end

      def get_resp
        LinkData.new(size: size, md5: md5, modified: modified, url: url, link_expiry: (Time.utc + AWS_S3_LINK_EXPIRY))
      end

      def set_metadata(meta)
        @metadata = meta
      end

      private def hostname
        if h = AWS_S3_ENDPOINT
          uri = URI.parse(h)
          "#{uri.hostname}:#{uri.port}"
        end
      end
    end
  end
end
