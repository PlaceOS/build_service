module Awscr
  module S3
    module Presigned
      class Url
        def for(method : Symbol, scheme = "https://")
          raise S3::Exception.new("unsupported method #{method}") unless allowed_methods.includes?(method)

          request = build_request(method.to_s.upcase)

          @options.additional_options.each do |k, v|
            request.query_params.add(k, v)
          end

          presign_request(request)

          String.build do |str|
            str << scheme
            str << host
            str << request.resource
          end
        end
      end
    end
  end
end
