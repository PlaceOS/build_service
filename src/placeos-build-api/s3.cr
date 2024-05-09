require "awscr-s3"
require "http/headers"
require "./utils"
require "../ext/url"

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
      commit = commit.lchop(RECOMPILE_PREFIX) if commit.starts_with?(RECOMPILE_PREFIX)
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

    def get(name)
      client.get_object(AWS_S3_BUCKET, name)
    end

    def put(driver_name : String, binary : IO, meta_name : String, meta : IO, defaults_name : String, defaults : IO)
      uploader = Awscr::S3::FileUploader.new(client)
      uploader.upload(AWS_S3_BUCKET, driver_name, binary)
      headers = {"Content-Type" => "application/json"}
      resp = head(driver_name)
      dinfo = DriverInfo.new(driver_name, resp.headers)
      dinfo.set_metadata(meta.gets_to_end)
      dinfo.set_defaults(defaults.gets_to_end)
      @@cache[driver_name] = dinfo
      meta.rewind
      client.put_object(AWS_S3_BUCKET, object: meta_name, body: meta, headers: headers)
      defaults.rewind
      client.put_object(AWS_S3_BUCKET, object: defaults_name, body: defaults, headers: headers)
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
      @defaults : String?

      @meta_name : String
      @defaults_name : String
      @driver_name : String

      def initialize(@name : String, headers : HTTP::Headers)
        parts = @name.split("_")
        @meta_name = parts[0...-1].concat(["meta"]).join("_")
        @defaults_name = parts[0...-1].concat(["defaults"]).join("_")
        @driver_name = parts[0...-1].concat([Api.arch]).join("_")
        @size = headers["content-length"].to_i64
        @md5 = headers["etag"].strip('"')
        @modified = Time::Format::RFC_2822.parse(headers["last-modified"])
      end

      def metadata : String
        @metadata ||= begin
          Api.with_s3 &.get("#{@meta_name}", &.gets_to_end)
        rescue ex
          Log.error { ex }
          raise ex
        end
      end

      def defaults : String
        @defaults ||= begin
          Api.with_s3 do |s3|
            s3.head(@defaults_name)
            s3.get("#{@defaults_name}", &.gets_to_end)
          rescue ex
            Log.error(exception: ex) { "Driver defaults not found. Fetching and getting default" }
            fetch_driver
          end
        end
      end

      def url : String
        scheme = "https://"
        host = nil
        if h = hostname
          scheme, host = h
        end
        options = Awscr::S3::Presigned::Url::Options.new(
          aws_access_key: AWS_KEY,
          aws_secret_key: AWS_SECRET,
          region: AWS_REGION,
          object: "/#{@name}",
          bucket: AWS_S3_BUCKET,
          host_name: host,
          expires: AWS_S3_LINK_EXPIRY.to_i.to_i32,
          additional_options: {
            "Content-Type" => "binary/octet-stream",
          })
        url = Awscr::S3::Presigned::Url.new(options)
        Log.debug { "Generating signed URL}" }
        url.for(:get, scheme)
      end

      def get_resp
        LinkData.new(size: size, md5: md5, modified: modified, url: url, link_expiry: (Time.utc + AWS_S3_LINK_EXPIRY))
      end

      def set_metadata(meta)
        @metadata = meta
      end

      def set_defaults(defaults)
        @defaults = defaults
      end

      private def fetch_driver
        Api.with_s3 do |s3|
          resp = s3.head(@driver_name)
          tempfile = File.tempfile
          begin
            resp = s3.get(@driver_name)
            File.open(tempfile.path, mode: "w+") do |f|
              f.write(resp.body.to_slice)
            end
            File.chmod(tempfile.path, 0o755)
            tempfile.close
            path = File.dirname(tempfile.path)
            dname = File.basename(tempfile.path)
            data = RunFrom.run_from(path, "./#{dname}", {"-d"})
            raise Api::Error.new("Unable to retrieve defaults. #{data.output}") unless data.status.success?
            data.output.rewind
            s3.client.put_object(AWS_S3_BUCKET, object: @defaults_name, body: data.output, headers: {"Content-Type" => "application/json"})
            data.output.rewind
            data.output.gets_to_end
          ensure
            tempfile.delete
          end
        end
      end

      private def hostname
        if h = AWS_S3_ENDPOINT
          uri = URI.parse(h)
          {"#{uri.scheme}://", "#{uri.hostname}:#{uri.port}"}
        end
      end
    end
  end
end
