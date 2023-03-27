require "awscr-s3"
require "json"
require "base64"
require "compress/gzip"
require "compress/zlib"

AWS_REGION      = "us-east-1"
AWS_KEY         = "root"
AWS_SECRET      = "password"
AWS_S3_ENDPOINT = "http://localhost:9000"
AWS_S3_BUCKET   = "placeos-drivers-build-service"

client = Awscr::S3::Client.new(AWS_REGION, AWS_KEY, AWS_SECRET, endpoint: AWS_S3_ENDPOINT)
resp = client.list_buckets
puts resp.buckets

meta = <<-J
{"interface":{"receive_webhook":{"method":{"type":"string","title":"String"},"headers":{"type":"object","additionalProperties":{"type":"array","items":{"type":"string"}},"title":"Hash(String,Array(String))"},"body":{"type":"string","title":"String"}},"device_list":{}},"functions":{"receive_webhook":{"method":["String"],"headers":["Hash(String,Array(String))"],"body":["String"]},"device_list":{}},"implements":[],"requirements":{},"security":{},"json_schema":{"type":"object","properties":{"https_insecure":{"type":"boolean"},"https_verify":{"anyOf":[{"type":"integer","format":"Int32"},{"type":"string"}]},"http_keep_alive_seconds":{"type":"integer","format":"UInt32"},"http_max_requests":{"type":"integer","format":"Int32"},"http_connect_timeout":{"type":"integer","format":"Int32"},"http_comms_timeout":{"type":"integer","format":"Int32"},"basic_auth":{"type":"object","properties":{"username":{"type":"string"},"password":{"type":"string"}},"required":["username","password"]},"proxy":{"type":"object","properties":{"host":{"type":"string"},"port":{"type":"integer","format":"Int32"},"auth":{"anyOf":[{"type":"object","properties":{"username":{"type":"string"},"password":{"type":"string"}},"required":["username","password"]},{"type":"null"}]}},"required":["host","port"]},"host_header":{"type":"string"},"debug_webhook":{"type":"boolean"},"device_list":{"type":"object","additionalProperties":{"type":"array","items":[{"type":"string"},{"type":"string"}]}},"manifest_list":{"type":"array","items":{"type":"string"}},"headers":{"type":"object","additionalProperties":{"anyOf":[{"type":"array","items":{"type":"string"}},{"type":"string"}]}},"multicast_hops":{"type":"integer","format":"UInt8"},"ssh":{"type":"object","properties":{"term":{"anyOf":[{"type":"null"},{"type":"string"}]},"keepalive":{"anyOf":[{"type":"integer","format":"Int32"},{"type":"null"}]},"username":{"type":"string"},"password":{"anyOf":[{"type":"null"},{"type":"string"}]},"passphrase":{"anyOf":[{"type":"null"},{"type":"string"}]},"private_key":{"anyOf":[{"type":"null"},{"type":"string"}]},"public_key":{"anyOf":[{"type":"null"},{"type":"string"}]}},"required":["username"]}},"required":["device_list","manifest_list"]}}
J
# resp = client.put_object(AWS_S3_BUCKET, "github.com/placeos/drivers/cams_drivers/drivers_leviton_acquisuite_54d3121", File.open("/Users/ali/Others/PlaceOS/drivers/binaries/bacnet-f598739-27b02d-1.1.1-ZHJpdmVycy9hc2hyYWU"))
# p! resp
resp = client.put_object(AWS_S3_BUCKET, "github.com/placeos/drivers/cams_drivers/drivers_leviton_acquisuite_54d3121_meta", meta)
p! resp

# resp = client.head_object(AWS_S3_BUCKET, "obj_with_meta")
# p! resp
# meta = resp.headers["x-amz-meta-meta"]?.presence
# puts JSON.parse(meta) unless meta.nil?

# comp = IO::Memory.new
# Compress::Zlib::Writer.open(comp, level: Compress::Zlib::BEST_COMPRESSION, &.write(meta.to_slice))
# comp.rewind
# comp_meta = Base64.urlsafe_encode(comp)
# p! comp_meta
# p! meta.size, comp_meta.size
