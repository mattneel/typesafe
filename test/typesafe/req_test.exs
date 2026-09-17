defmodule TypeSafe.ReqTest do
  use ExUnit.Case, async: true

  import TypeSafe.TransportHelpers

  alias TypeSafe.Answer
  alias TypeSafe.Client
  alias TypeSafe.Error
  alias TypeSafe.Response
  alias TypeSafe.Retry

  @moduletag :capture_log

  @base_url "https://api.typesafe.ai"

  describe "attach/2" do
    test "posts TypeSafe requests to /v1/systemone with auth and identification headers" do
      capture_requests(&json(&1, 200, systemone_body()))

      assert {:ok, %Req.Response{status: 200}} =
               Req.post(attached(), typesafe_state: %{ticket: "Payouts failing"}, typesafe_questions: questions())

      request = receive_request()
      assert %{method: "POST", scheme: :https, host: "api.typesafe.ai", path: "/v1/systemone"} = request
      assert request.json["state"] == %{"ticket" => "Payouts failing"}
      assert request.json["model"] == "jev-latest"
      assert request.json["questions"] |> Map.keys() |> Enum.sort() == ["department", "frustration", "is_urgent"]

      assert request.headers["authorization"] == ["Bearer ts_plugin_key"]
      assert request.headers["content-type"] == ["application/json"]
      assert request.headers["accept"] == ["application/json"]
      assert request.headers["user-agent"] == [Client.sdk()]
      assert request.headers["x-typesafe-sdk"] == [Client.sdk()]
      assert request.headers["x-typesafe-runtime"] == [Client.runtime()]
      refute Map.has_key?(request.headers, "x-typesafe-retry-count")
    end

    test "a TypeSafe request is always a POST" do
      capture_requests(&json(&1, 200, noul_body()))

      assert {:ok, %Req.Response{status: 200}} =
               Req.request(attached(), typesafe_state: "state", typesafe_questions: noul_question())

      assert %{method: "POST", path: "/v1/systemone"} = receive_request()
    end

    test "uses the model from attach/2, overridden by :typesafe_model per request" do
      capture_requests(&json(&1, 200, noul_body()))
      req = attached(model: "jev-preview")

      assert {:ok, _response} = Req.post(req, typesafe_state: "state", typesafe_questions: noul_question())
      assert receive_request().json["model"] == "jev-preview"

      assert {:ok, _response} =
               Req.post(req, typesafe_state: "state", typesafe_questions: noul_question(), typesafe_model: "jev-1.13.0")

      assert receive_request().json["model"] == "jev-1.13.0"
    end

    test "keeps an explicit URL, resolving a relative one against the base URL" do
      capture_requests(&json(&1, 200, noul_body()))
      req = attached(base_url: "https://gateway.example.com/ts/")

      assert {:ok, _response} =
               Req.post(req, url: "/v2/systemone", typesafe_state: "state", typesafe_questions: noul_question())

      assert %{host: "gateway.example.com", path: "/ts/v2/systemone"} = receive_request()

      assert {:ok, _response} =
               Req.post(req, url: "v2/systemone?trace=1", typesafe_state: "state", typesafe_questions: noul_question())

      assert %{host: "gateway.example.com", path: "/ts/v2/systemone", query: "trace=1"} = receive_request()

      assert {:ok, _response} =
               Req.post(req,
                 url: "https://eu.typesafe.example/v1/systemone",
                 typesafe_state: "state",
                 typesafe_questions: noul_question()
               )

      assert %{host: "eu.typesafe.example", path: "/v1/systemone"} = receive_request()
    end

    test "sends TypeSafe requests to the attach/2 base URL, ignoring the request's :base_url" do
      capture_requests(&json(&1, 200, noul_body()))
      request = Req.new(base_url: "https://proxy.internal/app", plug: {Req.Test, TypeSafe})

      req = TypeSafe.Req.attach(request, api_key: "k", retry: false)
      assert req.options.base_url == "https://proxy.internal/app"
      assert {:ok, _response} = Req.post(req, typesafe_state: "state", typesafe_questions: noul_question())
      assert %{host: "api.typesafe.ai", path: "/v1/systemone"} = receive_request()

      assert {:ok, _response} = Req.get(req, url: "/health")
      assert %{host: "proxy.internal", path: "/app/health"} = receive_request()

      req = TypeSafe.Req.attach(request, api_key: "k", base_url: "https://gateway.example.com/", retry: false)
      assert {:ok, _response} = Req.post(req, typesafe_state: "state", typesafe_questions: noul_question())
      assert %{host: "gateway.example.com", path: "/v1/systemone"} = receive_request()
    end

    test "TypeSafe requests use the bearer token while other requests keep the request's auth" do
      capture_requests(&json(&1, 200, noul_body()))
      req = attached(auth: {:basic, "user:pass"})

      assert req.options.auth == {:basic, "user:pass"}

      assert {:ok, _response} = Req.post(req, typesafe_state: "state", typesafe_questions: noul_question())
      assert receive_request().headers["authorization"] == ["Bearer ts_plugin_key"]

      assert {:ok, _response} = Req.get(req, url: "https://other.example.com/")
      assert receive_request().headers["authorization"] == ["Basic " <> Base.encode64("user:pass")]
    end

    test "sets no options on the request and keeps the API key out of inspect" do
      request = Req.new(plug: {Req.Test, TypeSafe})
      req = TypeSafe.Req.attach(request, api_key: "ts_plugin_key", retry: [max_retries: 5])

      assert req.options == request.options
      assert req.headers == request.headers
      refute inspect(req) =~ "ts_plugin_key"
      refute inspect(req.private) =~ "ts_plugin_key"
    end

    test "registers the TypeSafe options and prepends and appends its steps" do
      req = attached()
      step_names = Keyword.keys(req.request_steps)

      assert hd(step_names) == :typesafe_prepare
      assert List.last(step_names) == :typesafe_identification
      assert MapSet.subset?(MapSet.new([:typesafe_state, :typesafe_questions, :typesafe_model]), req.registered_options)

      assert_raise ArgumentError, ~r/unknown option :typesafe_stream/, fn ->
        Req.post(req, typesafe_stream: true)
      end
    end

    test "raises ArgumentError for unknown or invalid options" do
      assert_raise ArgumentError, ~r/unknown options \[:timeout\] for TypeSafe.Req.attach\/2/, fn ->
        TypeSafe.Req.attach(Req.new(), api_key: "k", timeout: 1_000)
      end

      assert_raise ArgumentError, ~r/expected an http\(s\) URL/, fn ->
        TypeSafe.Req.attach(Req.new(), api_key: "k", base_url: "typesafe")
      end

      assert_raise ArgumentError, ~r/invalid :retry for TypeSafe.Req.attach\/2/, fn ->
        TypeSafe.Req.attach(Req.new(), api_key: "k", retry: :forever)
      end
    end
  end

  describe "attach/2 retries" do
    test "defaults to the TypeSafe.Retry policy on TypeSafe requests" do
      options = prepared(TypeSafe.Req.attach(Req.new(), api_key: "k")).options

      assert is_function(options.retry, 2)
      assert options.max_retries == 2
      assert options.retry_log_level == :debug
      assert options.decode_body == false
      refute Map.has_key?(options, :retry_delay)
      assert options.retry.(Req.new(), Req.Response.new(status: 529)) != false
    end

    test "retries a POST on a transient failure, counting retries in the header" do
      test_pid = self()
      Req.Test.expect(TypeSafe, reporting(test_pid, &json(&1, 529, %{"detail" => "Overloaded"})))
      Req.Test.expect(TypeSafe, reporting(test_pid, &json(&1, 200, noul_body())))

      questions = noul_question()

      assert {:ok, %Response{answers: %{is_urgent: %Answer.Noul{noul: 0.95}}}} =
               [retry: [backoff_initial_ms: 0]]
               |> attached()
               |> Req.post(typesafe_state: "state", typesafe_questions: questions)
               |> TypeSafe.Req.decode(questions)

      assert Enum.map(receive_requests(), & &1.headers["x-typesafe-retry-count"]) == [nil, ["1"]]
      Req.Test.verify!(TypeSafe)
    end

    test "stamps the start time used by the retry budget" do
      capture_requests(&json(&1, 200, noul_body()))

      assert {:ok, _response} = Req.post(attached(), typesafe_state: "state", typesafe_questions: noul_question())
      assert is_integer(receive_request().private[:typesafe_started_at])
    end

    test "accepts a policy struct, retry options or false" do
      assert %{max_retries: 5} =
               prepared(TypeSafe.Req.attach(Req.new(), api_key: "k", retry: %Retry{max_retries: 5})).options

      assert %{max_retries: 1} = prepared(TypeSafe.Req.attach(Req.new(), api_key: "k", retry: [max_retries: 1])).options
      assert %{retry: false} = prepared(TypeSafe.Req.attach(Req.new(), api_key: "k", retry: false)).options

      assert_raise ArgumentError, ~r/invalid :retry for TypeSafe.Req.attach\/2: invalid TypeSafe.Retry options/, fn ->
        TypeSafe.Req.attach(Req.new(), api_key: "k", retry: %Retry{jitter: 3})
      end
    end

    test "retry: false makes one attempt" do
      Req.Test.expect(TypeSafe, &json(&1, 503, %{"detail" => "Service Unavailable"}))

      assert {:error, %Error{type: :server, status: 503}} =
               [retry: false]
               |> attached()
               |> Req.post(typesafe_state: "state", typesafe_questions: noul_question())
               |> TypeSafe.Req.decode(noul_question())

      Req.Test.verify!(TypeSafe)
    end

    test "retry: :keep leaves the request's own retry settings alone" do
      delay = fn _count -> 0 end

      options =
        [retry: :transient, max_retries: 7, retry_delay: delay]
        |> Req.new()
        |> TypeSafe.Req.attach(api_key: "k", retry: :keep)
        |> prepared()
        |> Map.fetch!(:options)

      assert options.retry == :transient
      assert options.max_retries == 7
      assert options.retry_delay == delay

      options = [] |> Req.new() |> TypeSafe.Req.attach(api_key: "k", retry: :keep) |> prepared() |> Map.fetch!(:options)
      refute Map.has_key?(options, :retry)
    end

    test "retry: :keep uses Req's own retries for TypeSafe requests" do
      Req.Test.expect(TypeSafe, &json(&1, 503, %{"detail" => "Service Unavailable"}))
      Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))

      assert {:ok, %Response{}} =
               [plug: {Req.Test, TypeSafe}, retry: :transient, retry_delay: 0]
               |> Req.new()
               |> TypeSafe.Req.attach(api_key: "k", retry: :keep)
               |> Req.post(typesafe_state: "state", typesafe_questions: noul_question())
               |> TypeSafe.Req.decode(noul_question())

      Req.Test.verify!(TypeSafe)
    end

    test "a :retry_delay on the request is dropped for TypeSafe requests under a policy" do
      Req.Test.expect(TypeSafe, &json(&1, 503, %{"detail" => "Service Unavailable"}))
      Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))

      req =
        [plug: {Req.Test, TypeSafe}, retry_delay: fn _count -> 0 end]
        |> Req.new()
        |> TypeSafe.Req.attach(api_key: "k", retry: [backoff_initial_ms: 0])

      refute Map.has_key?(prepared(req).options, :retry_delay)

      assert {:ok, %Response{}} =
               req
               |> Req.post(typesafe_state: "state", typesafe_questions: noul_question())
               |> TypeSafe.Req.decode(noul_question())

      assert is_function(req.options.retry_delay, 1)
      Req.Test.verify!(TypeSafe)
    end
  end

  describe "the prepare step" do
    setup do
      refute_network()
      :ok
    end

    test "raises :invalid_request for invalid questions before sending" do
      questions = %{severity: %TypeSafe.Question.Score{instructions: "Rate", criteria: ["Only one"]}}

      error =
        assert_raise Error, fn ->
          Req.post(attached(), typesafe_state: "state", typesafe_questions: questions)
        end

      assert %Error{type: :invalid_request, path: ["questions", "severity", "criteria"]} = error
    end

    test "raises :invalid_request for empty questions or an invalid state" do
      assert_raise Error, ~r/at least one question is required/, fn ->
        Req.post(attached(), typesafe_state: "state", typesafe_questions: %{})
      end

      assert_raise Error, ~r/state must be a string, map or list/, fn ->
        Req.post(attached(), typesafe_questions: noul_question())
      end
    end
  end

  describe "requests without :typesafe_questions" do
    test "pass through untouched, without the API key or TypeSafe headers" do
      capture_requests(&json(&1, 200, models_body()))

      assert {:ok, %Req.Response{status: 200, body: body}} = Req.get(attached(), url: "https://example.com/v1/models")
      assert body == models_body()

      request = receive_request()
      assert %{method: "GET", host: "example.com", path: "/v1/models", raw_body: ""} = request
      refute Map.has_key?(request.headers, "authorization")
      refute Map.has_key?(request.headers, "content-type")
      assert request.headers |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "x-typesafe")) == []
      assert ["req/" <> _] = request.headers["user-agent"]
      refute Map.has_key?(request.private, :typesafe_active)
      refute Map.has_key?(request.private, :typesafe_started_at)
    end

    test "a POST to another host is not retried by the TypeSafe policy and carries no key" do
      Req.Test.expect(TypeSafe, reporting(self(), &json(&1, 503, %{"ok" => false})))

      assert {:ok, %Req.Response{status: 503}} =
               [retry: [backoff_initial_ms: 0]]
               |> attached()
               |> Req.post(url: "https://payments.example.com/charge", json: %{amount: 100})

      assert [request] = receive_requests()
      assert %{method: "POST", host: "payments.example.com", path: "/charge"} = request
      assert request.json == %{"amount" => 100}
      refute Map.has_key?(request.headers, "authorization")
      refute Map.has_key?(request.headers, "x-typesafe-sdk")
      refute Map.has_key?(request.headers, "x-typesafe-runtime")
      Req.Test.verify!(TypeSafe)
    end

    test "keep the request's own retry settings" do
      Req.Test.expect(TypeSafe, 2, &json(&1, 503, %{"ok" => false}))

      assert {:ok, %Req.Response{status: 503}} =
               [plug: {Req.Test, TypeSafe}, retry: :transient, max_retries: 1, retry_delay: 0]
               |> Req.new()
               |> TypeSafe.Req.attach(api_key: "k", retry: [max_retries: 5, backoff_initial_ms: 0])
               |> Req.post(url: "https://other.example.com/jobs")

      Req.Test.verify!(TypeSafe)
    end

    test "ignore :typesafe_state on its own" do
      capture_requests(&Plug.Conn.send_resp(&1, 204, ""))

      assert {:ok, %Req.Response{status: 204}} = Req.delete(attached(), url: "/v1/cache", typesafe_state: "state")
      assert %{method: "DELETE", path: "/v1/cache", raw_body: ""} = receive_request()
    end
  end

  describe "decode/2" do
    test "decodes a successful {:ok, response} into a TypeSafe.Response" do
      capture_requests(&json(&1, 200, systemone_body()))
      questions = questions()

      assert {:ok, %Response{} = response} =
               attached()
               |> Req.post(typesafe_state: "state", typesafe_questions: questions)
               |> TypeSafe.Req.decode(questions)

      assert response.request_id == request_id()
      assert response.model == "jev-1.13.0"
      assert %Answer.Choice{choice: :billing} = response.answers.department
      assert %Answer.Score{legend: %{0 => "Calm"}} = response.answers.frustration
    end

    test "accepts a bare response with a JSON string body" do
      response =
        Req.Response.new(
          status: 200,
          body: JSON.encode!(noul_body()),
          headers: %{"x-typesafe-request-id" => ["req_raw"]}
        )

      assert {:ok, %Response{request_id: "req_raw", answers: %{is_urgent: %Answer.Noul{noul: 0.95}}}} =
               TypeSafe.Req.decode(response, noul_question())
    end

    test "maps a non-2xx response to a TypeSafe.Error" do
      response =
        Req.Response.new(
          status: 429,
          body: %{"error" => "rate limit exceeded"},
          headers: %{"retry-after-ms" => ["750"], "x-typesafe-request-id" => ["req_limited"]}
        )

      assert {:error, %Error{} = error} = TypeSafe.Req.decode({:ok, response}, noul_question())
      assert error.type == :rate_limited
      assert error.message == "rate limit exceeded"
      assert error.retry_after_ms == 750
      assert error.request_id == "req_limited"
      assert error.endpoint == nil
    end

    test "maps transport exceptions" do
      assert {:error, %Error{type: :timeout, reason: :timeout, endpoint: nil}} =
               TypeSafe.Req.decode({:error, %Req.TransportError{reason: :timeout}}, noul_question())

      assert {:error, %Error{type: :transport, reason: :econnrefused}} =
               TypeSafe.Req.decode({:error, %Req.TransportError{reason: :econnrefused}}, noul_question())
    end

    test "surfaces a transport failure from the attached request" do
      Req.Test.stub(TypeSafe, &Req.Test.transport_error(&1, :closed))

      assert {:error, %Error{type: :transport, reason: :closed}} =
               [retry: false]
               |> attached()
               |> Req.post(typesafe_state: "state", typesafe_questions: noul_question())
               |> TypeSafe.Req.decode(noul_question())
    end

    test "returns :invalid_response for a bad 2xx body, with the response's context" do
      body = noul_body("is_urgent", 7)
      headers = %{"x-typesafe-request-id" => ["req_invalid"]}

      for response_body <- [body, JSON.encode!(body)] do
        response = Req.Response.new(status: 200, body: response_body, headers: headers)

        assert {:error, %Error{type: :invalid_response, path: ["answers", "is_urgent", "noul"]} = error} =
                 TypeSafe.Req.decode(response, noul_question())

        assert %Error{status: 200, request_id: "req_invalid", headers: ^headers, body: ^body, endpoint: nil} = error
      end

      assert {:error, %Error{type: :invalid_response, status: 200, body: "<html></html>"}} =
               TypeSafe.Req.decode(Req.Response.new(status: 200, body: "<html></html>"), noul_question())
    end

    test "a TypeSafe request returns the raw body, which decode/2 decodes" do
      capture_requests(&json(&1, 200, noul_body()))

      assert {:ok, %Req.Response{body: raw} = response} =
               Req.post(attached(), typesafe_state: "state", typesafe_questions: noul_question())

      assert JSON.decode!(raw) == noul_body()

      assert {:ok, %Response{answers: %{is_urgent: %Answer.Noul{noul: 0.95}}}} =
               TypeSafe.Req.decode(response, noul_question())
    end

    test "a malformed body served as application/json is :invalid_response for a 2xx" do
      capture_requests(&bad_json(&1, 200))

      assert {:error, %Error{type: :invalid_response, status: 200, request_id: "req_bad_json"} = error} =
               attached()
               |> Req.post(typesafe_state: "state", typesafe_questions: noul_question())
               |> TypeSafe.Req.decode(noul_question())

      assert error.body == "<html>Bad gateway</html>"
    end

    test "a malformed 502 served as application/json is a retried :server error" do
      Req.Test.expect(TypeSafe, 3, &bad_json(&1, 502))

      assert {:error, %Error{type: :server, status: 502, body: "<html>Bad gateway</html>"}} =
               [retry: [backoff_initial_ms: 0]]
               |> attached()
               |> Req.post(typesafe_state: "state", typesafe_questions: noul_question())
               |> TypeSafe.Req.decode(noul_question())

      Req.Test.verify!(TypeSafe)
    end

    test "returns :invalid_request when the questions given to decode are invalid" do
      assert {:error, %Error{type: :invalid_request, path: ["questions"]}} =
               TypeSafe.Req.decode(Req.Response.new(status: 200, body: noul_body()), %{})
    end
  end

  test "emits no [:typesafe, :request, ...] telemetry" do
    ref = :telemetry_test.attach_event_handlers(self(), TypeSafe.Telemetry.events())
    on_exit(fn -> :telemetry.detach(ref) end)
    capture_requests(&json(&1, 200, noul_body()))
    base_url = "https://plugin-#{System.unique_integer([:positive])}.example.com"

    assert {:ok, _response} =
             [plug: {Req.Test, TypeSafe}]
             |> Req.new()
             |> TypeSafe.Req.attach(api_key: "k", base_url: base_url)
             |> Req.post(typesafe_state: "state", typesafe_questions: noul_question())

    assert %{host: "plugin-" <> _} = receive_request()
    refute_received {_event, ^ref, _measurements, %{base_url: ^base_url}}
  end

  defp attached(opts \\ []) do
    {req_options, opts} = Keyword.split(opts, [:auth])

    [plug: {Req.Test, TypeSafe}]
    |> Keyword.merge(req_options)
    |> Req.new()
    |> TypeSafe.Req.attach(Keyword.merge([api_key: "ts_plugin_key", base_url: @base_url], opts))
  end

  # Runs the prepare step on a TypeSafe request built from `req`, without sending it.
  defp prepared(req) do
    req
    |> Req.merge(typesafe_state: "state", typesafe_questions: noul_question())
    |> TypeSafe.Req.prepare()
  end

  defp bad_json(conn, status) do
    conn
    |> Plug.Conn.put_resp_header("x-typesafe-request-id", "req_bad_json")
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, "<html>Bad gateway</html>")
  end
end
