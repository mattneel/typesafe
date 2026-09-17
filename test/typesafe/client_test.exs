defmodule TypeSafe.ClientTest do
  use ExUnit.Case, async: true

  import TypeSafe.TestHelpers, only: [client: 0, client: 1]
  import TypeSafe.TransportHelpers

  alias TypeSafe.Client
  alias TypeSafe.Error
  alias TypeSafe.Retry

  @moduletag :capture_log

  @protected %{
    "Authorization" => "Bearer stolen",
    "Accept" => "text/html",
    "User-Agent" => "curl/8.0",
    "X-TypeSafe-SDK" => "fake-sdk/9.9.9",
    "X-TypeSafe-Runtime" => "fake-runtime",
    "X-TypeSafe-Retry-Count" => "7"
  }

  describe "new/1" do
    test "applies the documented defaults" do
      client = TypeSafe.new(api_key: "ts_test_key")

      assert %Client{
               api_key: "ts_test_key",
               base_url: "https://api.typesafe.ai",
               model: "jev-latest",
               timeout: 10_000,
               retry: %Retry{},
               headers: [],
               finch: nil,
               req_options: []
             } = client

      assert %Req.Request{} = client.req
    end

    test "TypeSafe.new/1 and TypeSafe.Client.new/1 build the same client" do
      opts = [api_key: "ts_test_key", model: "jev-preview", timeout: 2_000]
      assert Map.delete(TypeSafe.new(opts), :req) == Map.delete(Client.new(opts), :req)
    end

    test "strips trailing slashes from base_url" do
      assert TypeSafe.new(api_key: "k", base_url: "https://proxy.example.com/typesafe/").base_url ==
               "https://proxy.example.com/typesafe"

      assert TypeSafe.new(api_key: "k", base_url: "https://api.typesafe.ai//").base_url == "https://api.typesafe.ai"
    end

    test "accepts http and https base URLs with ports and paths" do
      for url <- ["http://localhost:4000", "https://api.typesafe.ai", "https://gateway.internal:8443/ts"] do
        assert TypeSafe.new(api_key: "k", base_url: url).base_url == url
      end
    end

    test "casts :retry from a keyword list, a struct or false" do
      assert TypeSafe.new(api_key: "k", retry: [max_retries: 5]).retry == %Retry{max_retries: 5}
      assert TypeSafe.new(api_key: "k", retry: %Retry{budget_ms: nil}).retry == %Retry{budget_ms: nil}
      assert TypeSafe.new(api_key: "k", retry: false).retry == false
    end

    test "normalises :headers from a map or list, downcasing names and stringifying values" do
      assert TypeSafe.new(api_key: "k", headers: [{"X-Team", "support"}, {:x_priority, 1}, {"x-flag", true}]).headers ==
               [{"x-team", "support"}, {"x-priority", "1"}, {"x-flag", "true"}]

      assert TypeSafe.new(api_key: "k", headers: %{"X-Team" => :support}).headers == [{"x-team", "support"}]
    end

    test "atom header names use dashes, as in Req, while string names are kept" do
      headers = [{:x_request_source, "batch"}, {:X_Upper_Atom, "a"}, {"x_string_name", "kept"}]

      assert TypeSafe.new(api_key: "k", headers: headers).headers ==
               [{"x-request-source", "batch"}, {"x-upper-atom", "a"}, {"x_string_name", "kept"}]

      assert TypeSafe.new(api_key: "k", headers: [x_typesafe_sdk: "fake", user_agent: "curl"]).headers == []
    end

    test "atom header names are sent dashed, on the client and per call" do
      capture_requests(&json(&1, 200, models_body()))

      assert {:ok, _models} = TypeSafe.list_models(client(headers: [x_request_source: "batch"]), headers: [x_call: 1])

      headers = receive_request().headers
      assert headers["x-request-source"] == ["batch"]
      assert headers["x-call"] == ["1"]
      refute Map.has_key?(headers, "x_request_source")
    end

    test "silently drops protected header names from :headers" do
      headers = Map.put(@protected, "X-Custom", "kept")
      assert TypeSafe.new(api_key: "k", headers: headers).headers == [{"x-custom", "kept"}]
    end

    test "treats an explicit nil like an absent option" do
      client = TypeSafe.new(api_key: "k", base_url: nil, model: nil, timeout: nil, retry: nil, headers: nil)

      assert client.base_url == "https://api.typesafe.ai"
      assert client.model == "jev-latest"
      assert client.timeout == 10_000
      assert client.retry == %Retry{}
      assert client.headers == []
    end

    test "raises ArgumentError for invalid options" do
      cases = [
        {[api_key: ""], ~r/at least 1 character.*api_key/},
        {[api_key: 123], ~r/api_key/},
        {[api_key: "k", base_url: "ftp://files.example.com"], ~r/expected an http\(s\) URL/},
        {[api_key: "k", base_url: "api.typesafe.ai"], ~r/expected an http\(s\) URL/},
        {[api_key: "k", base_url: "https://"], ~r/expected an http\(s\) URL/},
        {[api_key: "k", model: ""], ~r/model/},
        {[api_key: "k", timeout: 0], ~r/timeout/},
        {[api_key: "k", timeout: 1.5], ~r/timeout/},
        {[api_key: "k", retry: true], ~r/expected a TypeSafe.Retry, a keyword list or false/},
        {[api_key: "k", retry: [max_retries: -1]], ~r/invalid TypeSafe.Retry options/},
        {[api_key: "k", retry: [:fast]], ~r/invalid TypeSafe.Retry options: expected a keyword list/},
        {[api_key: "k", headers: "x-team: support"], ~r/expected headers as a map or list/},
        {[api_key: "k", headers: [{"x-team", %{}}]], ~r/expected headers as \{name, value\} pairs/},
        {[api_key: "k", finch: MyApp.Finch], ~r/expected a keyword list, at finch/},
        {[api_key: "k", finch: [:pool]], ~r/expected a keyword list, at finch/},
        {[api_key: "k", req_options: :plug], ~r/expected a keyword list, at req_options/},
        {[api_key: "k", req_options: [:plug]], ~r/expected a keyword list, at req_options/},
        {[api_key: "k", stream: true], ~r/unrecognized key: stream/}
      ]

      for {opts, message} <- cases do
        assert_raise ArgumentError, message, fn -> TypeSafe.new(opts) end
      end
    end

    test "raises ArgumentError when the options are not a keyword list" do
      for opts <- [[{"api_key", "k"}], %{api_key: "k"}, "ts_test_key", nil] do
        assert_raise ArgumentError, ~r/expected TypeSafe options as a keyword list/, fn -> TypeSafe.new(opts) end
        assert_raise ArgumentError, ~r/expected TypeSafe options as a keyword list/, fn -> Client.new(opts) end
      end
    end

    test "validates a :retry policy struct" do
      for policy <- [%Retry{jitter: 3}, %Retry{max_retries: -1}, %Retry{statuses: 500..599}] do
        assert_raise ArgumentError, ~r/invalid TypeSafe.Retry options/, fn ->
          TypeSafe.new(api_key: "k", retry: policy)
        end
      end
    end

    test "raises ArgumentError for :retry_delay in :req_options while retry is a policy" do
      error =
        assert_raise ArgumentError, fn ->
          TypeSafe.new(api_key: "k", req_options: [retry_delay: fn _count -> 0 end])
        end

      assert error.message =~ ":retry_delay in :req_options conflicts with the TypeSafe retry policy"
      assert error.message =~ "retry: [backoff_initial_ms: 0]"

      assert_raise ArgumentError, ~r/:retry_delay/, fn ->
        TypeSafe.new(api_key: "k", retry: [max_retries: 1], req_options: [retry_delay: 10])
      end
    end

    test "allows :retry_delay in :req_options with retry: false" do
      client = TypeSafe.new(api_key: "k", retry: false, req_options: [retry_delay: 10])

      assert client.req.options.retry_delay == 10
      assert client.req.options.retry == false
    end
  end

  describe "inspect" do
    test "hides the API key and the Req request" do
      client = TypeSafe.new(api_key: "ts_live_super_secret", headers: %{"x-team" => "support"})
      inspected = inspect(client)

      assert inspected =~ "#TypeSafe.Client<"
      assert inspected =~ ~s(base_url: "https://api.typesafe.ai")
      assert inspected =~ ~s(model: "jev-latest")
      refute inspected =~ "ts_live_super_secret"
      refute inspected =~ "api_key"
      refute inspected =~ "Req.Request"
    end
  end

  describe "identification headers" do
    test "are sent on every request" do
      capture_requests(&json(&1, 200, noul_body()))

      assert {:ok, _response} = TypeSafe.ask(client(), "state", noul_question())

      headers = receive_request().headers
      assert headers["authorization"] == ["Bearer ts_test_key"]
      assert headers["accept"] == ["application/json"]
      assert headers["user-agent"] == [Client.sdk()]
      assert headers["x-typesafe-sdk"] == [Client.sdk()]
      assert headers["x-typesafe-runtime"] == [Client.runtime()]
      assert headers["content-type"] == ["application/json"]
      refute Map.has_key?(headers, "x-typesafe-retry-count")
    end

    test "are sent when the client's Req request is used directly" do
      capture_requests(&json(&1, 200, models_body()))

      assert {:ok, %Req.Response{status: 200}} = Req.get(client().req, url: "/v1/models")
      assert_identification(receive_request().headers)
    end

    test "sdk/0 embeds the package version" do
      assert Client.sdk() == "typesafe-elixir/#{Application.spec(:typesafe, :vsn)}"
      assert Client.sdk() =~ ~r/^typesafe-elixir\/\d+\.\d+\.\d+/
    end

    test "runtime/0 describes Elixir, OTP, OS and architecture" do
      version = Regex.escape(System.version())
      otp = Regex.escape(System.otp_release())

      assert Client.runtime() =~ ~r/^elixir\/#{version} \(otp\/#{otp}; [a-z0-9_]+; [A-Za-z0-9_]+\)$/
      assert Client.runtime() == Client.runtime()
    end

    test "cannot be overridden through client :headers" do
      capture_requests(&json(&1, 200, noul_body()))

      assert {:ok, _response} = TypeSafe.ask(client(headers: @protected), "state", noul_question())
      assert_identification(receive_request().headers)
    end

    test "cannot be overridden through per-call :headers" do
      capture_requests(&json(&1, 200, models_body()))

      assert {:ok, _models} = TypeSafe.list_models(client(), headers: @protected)
      assert_identification(receive_request().headers)
    end

    test "cannot be overridden through :req_options headers" do
      capture_requests(&json(&1, 200, noul_body()))
      req_options = [plug: {Req.Test, TypeSafe}, headers: Map.to_list(@protected)]

      assert {:ok, _response} = TypeSafe.ask(client(req_options: req_options), "state", noul_question())
      assert_identification(receive_request().headers)
    end

    test "content-type stays application/json for a POST even when a header says otherwise" do
      capture_requests(&json(&1, 200, noul_body()))

      assert {:ok, _response} =
               TypeSafe.ask(client(), "state", noul_question(), headers: %{"content-type" => "text/plain"})

      assert receive_request().headers["content-type"] == ["application/json"]
    end
  end

  describe "base_url" do
    test "joins paths onto the default host" do
      capture_requests(&json(&1, 200, noul_body()))

      assert {:ok, _response} = TypeSafe.ask(client(), "state", noul_question())

      assert %{scheme: :https, host: "api.typesafe.ai", port: 443, path: "/v1/systemone"} = receive_request()
    end

    test "keeps a path prefix, with or without a trailing slash" do
      capture_requests(&json(&1, 200, models_body()))

      for base_url <- ["https://proxy.example.com/typesafe/", "https://proxy.example.com/typesafe"] do
        assert {:ok, _models} = TypeSafe.list_models(client(base_url: base_url))
        assert %{host: "proxy.example.com", path: "/typesafe/v1/models"} = receive_request()
      end
    end

    test "supports plain http with a port" do
      capture_requests(&json(&1, 200, noul_body()))

      assert {:ok, _response} = TypeSafe.ask(client(base_url: "http://localhost:4000"), "state", noul_question())
      assert %{scheme: :http, host: "localhost", port: 4000, path: "/v1/systemone"} = receive_request()
    end

    test "is used in the error endpoint" do
      capture_requests(&json(&1, 404, %{"detail" => "Not Found"}))

      assert {:error, %Error{endpoint: "POST https://proxy.example.com/typesafe/v1/systemone"}} =
               TypeSafe.ask(client(base_url: "https://proxy.example.com/typesafe/"), "state", noul_question())
    end
  end

  describe "request/2" do
    test "unknown options raise ArgumentError" do
      refute_network()

      assert_raise ArgumentError, ~r/unknown options \[:body\] for TypeSafe.Client.request\/2/, fn ->
        Client.request(client(), url: "/v1/models", body: "{}")
      end
    end

    test "sends a GET by default and returns the raw Req.Response for a 2xx" do
      capture_requests(&json(&1, 200, models_body()))

      assert {:ok, %Req.Response{status: 200, body: body} = response} =
               Client.request(client(), url: "/v1/models")

      assert body == models_body()
      assert response.headers["x-typesafe-request-id"] == [request_id()]

      request = receive_request()
      assert %{method: "GET", path: "/v1/models", raw_body: ""} = request
      assert_identification(request.headers)
      refute Map.has_key?(request.headers, "content-type")
    end

    test "encodes :json as the body with a JSON content type" do
      capture_requests(&Plug.Conn.send_resp(&1, 204, ""))

      assert {:ok, %Req.Response{status: 204}} =
               Client.request(client(), method: :post, url: "/v1/feedback", json: %{rating: 5, tags: ["fast"]})

      request = receive_request()
      assert %{method: "POST", path: "/v1/feedback", json: %{"rating" => 5, "tags" => ["fast"]}} = request
      assert request.headers["content-type"] == ["application/json"]
    end

    test "decodes a JSON body whatever the content type, and keeps text and empty bodies" do
      Req.Test.expect(TypeSafe, &text(&1, 200, ~s({"ok": true})))
      Req.Test.expect(TypeSafe, &json(&1, 200, %{"ok" => true}))
      Req.Test.expect(TypeSafe, &text(&1, 200, "plain text"))
      Req.Test.expect(TypeSafe, &Plug.Conn.send_resp(&1, 200, ""))

      assert {:ok, %Req.Response{body: %{"ok" => true}}} = Client.request(client(), url: "/v1/status")
      assert {:ok, %Req.Response{body: %{"ok" => true}}} = Client.request(client(), url: "/v1/status")
      assert {:ok, %Req.Response{body: "plain text"}} = Client.request(client(), url: "/v1/status")
      assert {:ok, %Req.Response{body: ""}} = Client.request(client(), url: "/v1/status")
      Req.Test.verify!(TypeSafe)
    end

    test "returns :invalid_request for a body that cannot be encoded, without a request" do
      refute_network()

      assert {:error, %Error{type: :invalid_request, message: "request body is not valid JSON: " <> _}} =
               Client.request(client(), method: :post, url: "/v1/feedback", json: %{pid: self()})
    end

    test "returns a TypeSafe.Error for a non-2xx status" do
      capture_requests(&json(&1, 404, %{"detail" => "Not Found"}))

      assert {:error, %Error{type: :not_found, status: 404, message: "Not Found"} = error} =
               Client.request(client(), method: :delete, url: "/v1/nope")

      assert error.endpoint == "DELETE https://api.typesafe.ai/v1/nope"
    end

    test "returns a TypeSafe.Error for a transport failure" do
      Req.Test.stub(TypeSafe, &Req.Test.transport_error(&1, :closed))

      assert {:error, %Error{type: :transport, reason: :closed}} =
               Client.request(client(), url: "/v1/models", retry: false)
    end

    test "applies the client's retry policy and per-call overrides" do
      Req.Test.expect(TypeSafe, &json(&1, 503, %{"detail" => "Service Unavailable"}))
      Req.Test.expect(TypeSafe, reporting(self(), &json(&1, 200, models_body())))
      client = reporting_options(client())

      assert {:ok, %Req.Response{status: 200}} =
               Client.request(client, url: "/v1/models", timeout: 750, headers: [{"x-call", "1"}])

      assert receive_request().headers["x-call"] == ["1"]
      assert_received {:typesafe_options, %{receive_timeout: 750}}
      Req.Test.verify!(TypeSafe)
    end

    test "requires a :url path" do
      assert_raise ArgumentError, "TypeSafe.Client.request/2 requires a :url path", fn ->
        Client.request(client(), method: :get)
      end
    end

    test "raises ArgumentError for invalid per-call options" do
      assert_raise ArgumentError, ~r/invalid TypeSafe call options/, fn ->
        Client.request(client(), url: "/v1/models", timeout: -1)
      end
    end
  end

  describe "connection pool exhaustion" do
    test "a Finch pool checkout timeout returns a retryable transport error instead of raising" do
      Req.Test.stub(TypeSafe, fn _conn ->
        raise "Finch was unable to provide a connection within the timeout due to excess queuing for connections."
      end)

      assert {:error, %Error{type: :transport, reason: :pool_timeout} = error} =
               TypeSafe.ask(client(), "state", noul_question())

      assert error.message =~ "unable to provide a connection"
      assert error.endpoint == "POST https://api.typesafe.ai/v1/systemone"
      assert Error.retryable?(error)
    end

    test "other exceptions raised by the transport still propagate" do
      Req.Test.stub(TypeSafe, fn _conn -> raise "boom" end)

      assert_raise RuntimeError, "boom", fn -> TypeSafe.ask(client(), "state", noul_question()) end
    end
  end

  describe "Req options" do
    test "compile the client options into the Req request" do
      client = TypeSafe.new(api_key: "ts_test_key", timeout: 2_500, retry: [max_retries: 4])
      options = client.req.options

      assert options.base_url == "https://api.typesafe.ai"
      assert options.auth == {:bearer, "ts_test_key"}
      assert options.receive_timeout == 2_500
      assert options.decode_body == false
      refute Map.has_key?(options, :connect_options)
      assert is_function(options.retry, 2)
      assert options.max_retries == 4
      assert options.retry_log_level == :debug
      refute Map.has_key?(options, :retry_delay)
      refute Map.has_key?(options, :finch)
    end

    test "the retry function is the policy's decide/3" do
      policy = Retry.new(backoff_initial_ms: 40, jitter: 0)
      retry = TypeSafe.new(api_key: "k", retry: policy).req.options.retry

      assert retry.(Req.new(), Req.Response.new(status: 503)) == {:delay, 40}
      assert retry.(Req.new(), Req.Response.new(status: 400)) == false
    end

    test "retry: false disables Req retries" do
      options = TypeSafe.new(api_key: "k", retry: false).req.options

      assert options.retry == false
      refute Map.has_key?(options, :max_retries)
    end

    test ":finch is passed to Req" do
      options = TypeSafe.new(api_key: "k", finch: [name: MyApp.TypeSafeFinch], timeout: 3_000).req.options

      assert options.finch == [name: MyApp.TypeSafeFinch]
      assert options.receive_timeout == 3_000
      refute Map.has_key?(options, :connect_options)
    end

    test "a :finch in :req_options is passed to Req without connect options" do
      options = TypeSafe.new(api_key: "k", req_options: [finch: [name: MyApp.TypeSafeFinch]]).req.options

      assert options.finch == [name: MyApp.TypeSafeFinch]
      refute Map.has_key?(options, :connect_options)
    end

    test "per-call :timeout does not add connect options to a Finch client" do
      capture_requests(&json(&1, 200, noul_body()))
      client = reporting_options(client(finch: [name: MyApp.TypeSafeFinch]))

      assert {:ok, _response} = TypeSafe.ask(client, "state", noul_question(), timeout: 900)
      assert_received {:typesafe_options, options}
      assert options.receive_timeout == 900
      refute Map.has_key?(options, :connect_options)
    end

    test ":req_options are merged last and win" do
      client =
        TypeSafe.new(
          api_key: "k",
          timeout: 2_000,
          req_options: [receive_timeout: 99, retry_log_level: :warning, plug: {Req.Test, TypeSafe}]
        )

      assert client.req.options.receive_timeout == 99
      assert client.req.options.retry_log_level == :warning
      assert client.req.options.plug == {Req.Test, TypeSafe}
      assert client.req_options == [receive_timeout: 99, retry_log_level: :warning, plug: {Req.Test, TypeSafe}]
    end

    test "connect options come only from :req_options, unchanged by :timeout" do
      options =
        TypeSafe.new(api_key: "k", timeout: 4_000, req_options: [connect_options: [protocols: [:http2]]]).req.options

      assert options.connect_options == [protocols: [:http2]]
      assert options.receive_timeout == 4_000

      options = TypeSafe.new(api_key: "k", timeout: 4_000, req_options: [connect_options: [timeout: 250]]).req.options

      assert options.connect_options == [timeout: 250]
      assert options.receive_timeout == 4_000
    end

    test "per-call :timeout sets only the receive timeout" do
      capture_requests(&json(&1, 200, noul_body()))
      client = reporting_options(client(timeout: 5_000))

      for timeout <- [1_000, 1_001, 1_002] do
        assert {:ok, _response} = TypeSafe.ask(client, "state", noul_question(), timeout: timeout)
        assert_received {:typesafe_options, options}
        assert options.receive_timeout == timeout
        refute Map.has_key?(options, :connect_options)
      end
    end

    test "a client with its own Finch pool makes real requests, with per-call timeouts" do
      base_url = start_http_server(200, noul_body())
      finch = :"typesafe_client_test_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch})

      for client <- [
            TypeSafe.new(api_key: "k", base_url: base_url, retry: false, finch: [name: finch]),
            TypeSafe.new(api_key: "k", base_url: base_url, retry: false, req_options: [finch: [name: finch]])
          ] do
        assert {:ok, %TypeSafe.Response{request_id: "req_01a0ac5f3b2e4d6c8a9b"}} =
                 TypeSafe.ask(client, "state", noul_question())

        assert {:ok, %TypeSafe.Response{}} = TypeSafe.ask(client, "state", noul_question(), timeout: 1_234)
      end
    end

    test "a :retry_delay inherited by a retry: false client is dropped for a per-call policy" do
      Req.Test.expect(TypeSafe, &json(&1, 503, %{"detail" => "Service Unavailable"}))
      Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))
      client = client(retry: false, req_options: [plug: {Req.Test, TypeSafe}, retry_delay: fn _count -> 0 end])

      assert {:ok, %TypeSafe.Response{}} =
               TypeSafe.ask(client, "state", noul_question(), retry: [backoff_initial_ms: 0, max_retries: 1])

      Req.Test.verify!(TypeSafe)
    end

    test "the identification step runs after every other request step" do
      steps = TypeSafe.new(api_key: "k").req.request_steps

      assert {:typesafe_identification, _step} = List.last(steps)
    end
  end

  defp assert_identification(headers) do
    assert headers["authorization"] == ["Bearer ts_test_key"]
    assert headers["accept"] == ["application/json"]
    assert headers["user-agent"] == [Client.sdk()]
    assert headers["x-typesafe-sdk"] == [Client.sdk()]
    assert headers["x-typesafe-runtime"] == [Client.runtime()]
    refute Map.has_key?(headers, "x-typesafe-retry-count")
  end
end
