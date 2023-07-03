require "./spec_helper"

module PlaceOS::Api
  describe Driver do
    client = AC::SpecHelper.client
    namespace = Driver::NAMESPACE[0]
    json_headers = HTTP::Headers{
      "Content-Type" => "application/json",
    }
    uri = URI.encode_www_form("drivers/place/private_helper.cr")
    params = HTTP::Params{
      "url"    => "https://github.com/placeos/private-drivers",
      "branch" => "master",
      "commit" => "057e4e1cf6eadc2af0699d9f0fd5470baf6f7011",
    }

    describe "build/" do
      it "request-id and date headers are set properly" do
        resp = client.get("#{namespace}/", headers: json_headers)
        resp.body.should eq({health: "ok"}.to_json)
        resp.headers["Date"].should_not be_nil
        resp.headers["X-Request-ID"].should_not be_nil
      end

      it "returns details of service" do
        resp = client.get("#{namespace}/version", headers: json_headers)
        resp.body.should eq({
          version:    VERSION,
          build_time: BUILD_TIME,
          commit:     BUILD_COMMIT,
          service:    APP_NAME,
        }.to_json)
      end

      it "checks if a driver has been compiled? which hasn't yet" do
        resp = client.get("#{namespace}/metadata/#{uri}1?#{params}")
        resp.status_code.should eq 404
      end

      it "request to compile driver should handle git failure" do
        prms = HTTP::Params{
          "url"    => "https://github.com/placeos/private-drivers",
          "branch" => "master",
          "commit" => "abcxyzaa",
        }
        resp = client.post("#{namespace}/#{Api.arch}/#{uri}?#{prms}")
        resp.status_code.should eq 202

        task = TaskStatus.from_json(resp.body)
        location = "#{namespace}/#{Api.arch}/task/#{task.id}"
        hdr = resp.headers["Content-Location"]?
        hdr.should_not be_nil
        location.should eq(hdr)

        task.state.to_s.should eq("pending")
        task.repo.should eq("https://github.com/placeos/private-drivers")
        task.driver.should eq("drivers/place/private_helper.cr")
        task.branch.should eq("master")
        task.commit.should eq("abcxyzaa")

        loop do
          resp = client.get(location)
          task = TaskStatus.from_json(resp.body)
          break if task.state.to_s != "pending"
          resp.status_code.should eq 200
          sleep 5
        end
        resp.status_code.should eq 200
        task.state.to_s.should eq("error")
        task.message.includes?("failed to git checkout").should be_true
      end

      it "it should compile driver" do
        resp = client.post("#{namespace}/#{Api.arch}/#{uri}?#{params}")
        resp.status_code.should eq 202
        second = client.post("#{namespace}/#{Api.arch}/#{uri}?#{params}")
        second.status_code.should eq 202

        resp.body.should eq(second.body)

        task = TaskStatus.from_json(resp.body)
        location = "#{namespace}/#{Api.arch}/task/#{task.id}"
        hdr = resp.headers["Content-Location"]?
        hdr.should_not be_nil
        location.should eq(hdr)

        task.state.to_s.should eq("pending")
        task.repo.should eq("https://github.com/placeos/private-drivers")
        task.driver.should eq("drivers/place/private_helper.cr")
        task.branch.should eq("master")
        task.commit.should eq("057e4e1cf6eadc2af0699d9f0fd5470baf6f7011")

        loop do
          resp = client.get(location)
          task = TaskStatus.from_json(resp.body)
          break if task.state.to_s != "pending"
          resp.status_code.should eq 200
          sleep 5
        end
        resp.status_code.should eq 303
        task.state.to_s.should eq("done")

        location = "#{namespace}/#{Api.arch}/compiled/#{uri}?#{params}"
        hdr = resp.headers["Location"]?
        hdr.should_not be_nil
        location.should eq(hdr)

        resp = client.get(location)
        resp.status_code.should eq 200
        json = JSON.parse(resp.body).as_h
        {"size", "md5", "modified", "url", "link_expiry"}.each do |k|
          json.has_key?(k).should be_true
        end
      end

      it "checks if a driver has been compiled" do
        resp = client.get("#{namespace}/#{Api.arch}/compiled/#{uri}?#{params}")
        resp.status_code.should eq 200
        json = JSON.parse(resp.body).as_h
        {"size", "md5", "modified", "url", "link_expiry"}.each do |k|
          json.has_key?(k).should be_true
        end
      end

      it "compiled driver should return metadata" do
        resp = client.get("#{namespace}/metadata/#{uri}?#{params}")
        resp.status_code.should eq 200
        JSON.parse(resp.body) # doing it to ensure we are receiving valid JSON
      end
    end
  end
end
