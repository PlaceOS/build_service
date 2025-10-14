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
          break if task.completed?
          resp.status_code.should eq 200
          sleep 5.seconds
        end
        resp.status_code.should eq 200
        task.state.to_s.should eq("error")
      end

      it "it should compile driver" do
        # checks if a driver has been compiled? which hasn't yet
        resp = client.get("#{namespace}/metadata/#{uri}1?#{params}")
        resp.status_code.should eq 404

        resp = client.post("#{namespace}/#{Api.arch}/#{uri}?#{params}")
        resp.status_code.should eq 202
        second = client.post("#{namespace}/#{Api.arch}/#{uri}?#{params}")
        second.status_code.should eq 202

        t1 = TaskStatus.from_json(resp.body)
        t2 = TaskStatus.from_json(second.body)

        t1.should eq(t2)

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
          break if task.completed?
          resp.status_code.should eq 200
          sleep 5.seconds
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

        # checks if a driver has been compiled
        resp = client.get("#{namespace}/#{Api.arch}/compiled/#{uri}?#{params}")
        resp.status_code.should eq 200
        json = JSON.parse(resp.body).as_h
        {"size", "md5", "modified", "url", "link_expiry"}.each do |k|
          json.has_key?(k).should be_true
        end

        json["url"].as_s.starts_with?(PlaceOS::Api::AWS_S3_ENDPOINT.not_nil!).should be_true
        # compiled driver should return metadata
        resp = client.get("#{namespace}/metadata/#{uri}?#{params}")
        resp.status_code.should eq 200
        JSON.parse(resp.body) # doing it to ensure we are receiving valid JSON
        # compiled driver should return defaults
        resp = client.get("#{namespace}/defaults/#{uri}?#{params}")
        resp.status_code.should eq 200
        JSON.parse(resp.body) # doing it to ensure we are receiving valid JSON
      end

      it "should handle duplicate request" do
        prms = HTTP::Params{
          "url"    => "https://github.com/placeos/private-drivers",
          "branch" => "master",
          "commit" => "abcxyzaa",
        }

        resp = client.post("#{namespace}/#{Api.arch}/#{uri}?#{prms}")
        resp.status_code.should eq 202

        task = TaskStatus.from_json(resp.body)

        # send same request again
        resp = client.post("#{namespace}/#{Api.arch}/#{uri}?#{prms}")
        resp.status_code.should eq 202
        task2 = TaskStatus.from_json(resp.body)
        task2.id.should eq(task.id)
      end

      it "should return a list of pending jobs" do
        0.upto(3) do |i|
          prms = HTTP::Params{
            "url"    => "https://github.com/placeos/private-drivers",
            "branch" => "master",
            "commit" => "abcxyzaa#{i}",
          }
          client.post("#{namespace}/#{Api.arch}/#{uri}?#{prms}")
        end
        resp = client.get("#{namespace}/monitor")
        resp.status_code.should eq 200
        queue = Array(TaskStatus).from_json(resp.body)
        queue.size.should be > 0
      end

      it "should handle undone jobs on startup" do
        state = Api.get_incomplete_tasks.map { |t| {t.id, t.state} }
        Api.on_start
        pending, cancelled = state.partition { |_, s| s == Api::State::Pending }
        cancelled.each { |c| Api.running?(c[0]).should be_false }
        pending.each { |c| Api.running?(c[0]).should be_true }
      end

      it "should return with 404 when cancelling a non pending jobs" do
        code = TOTP.generate_number_string(Api::TOTP_SECRET)
        auth_headers = HTTP::Headers{
          "Authorization" => Base64.strict_encode(":#{code}"),
        }

        client.delete("#{namespace}/cancel/abcxyze", headers: auth_headers).status_code.should eq(404)
      end

      it "cancelling a job should return 401 if unauthorized" do
        client.delete("#{namespace}/cancel/abcxyz").status_code.should eq(401)
      end

      it "should cancel pending jobs" do
        prms = HTTP::Params{
          "url"    => "https://github.com/placeos/private-drivers",
          "branch" => "master",
          "commit" => "abcxyzaa",
        }

        resp = client.post("#{namespace}/#{Api.arch}/#{uri}?#{prms}")
        resp.status_code.should eq 202
        task = TaskStatus.from_json(resp.body)

        code = TOTP.generate_number_string(Api::TOTP_SECRET)
        auth_headers = HTTP::Headers{
          "Authorization" => Base64.strict_encode(":#{code}"),
        }

        resp = client.delete("#{namespace}/cancel/#{task.id}", headers: auth_headers)
        status = JSON.parse(resp.body).as_h
        status["status"].should eq("success")
        status["message"].should eq("Job with id #{task.id} cancelled successfully")
      end
    end
  end
end
