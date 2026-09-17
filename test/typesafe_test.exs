defmodule TypeSafeTest do
  use ExUnit.Case, async: true

  import TypeSafe.TestHelpers, only: [client: 0, client: 1]
  import TypeSafe.TransportHelpers

  alias TypeSafe.Answer
  alias TypeSafe.Client
  alias TypeSafe.Error
  alias TypeSafe.Model
  alias TypeSafe.Response
  alias TypeSafe.Usage

  @moduletag :capture_log

  @state "Help! My payouts have been failing for 3 days."

  describe "ask/4" do
    test "posts state, model and questions to /v1/systemone and decodes every answer type" do
      capture_requests(&json(&1, 200, systemone_body()))

      assert {:ok, %Response{} = response} = TypeSafe.ask(client(), @state, questions())

      request = receive_request()
      assert request.method == "POST"
      assert request.scheme == :https
      assert request.host == "api.typesafe.ai"
      assert request.path == "/v1/systemone"
      assert request.headers["content-type"] == ["application/json"]
      assert request.headers["authorization"] == ["Bearer ts_test_key"]

      assert %{"state" => @state, "model" => "jev-latest", "questions" => sent} = request.json

      assert sent == %{
               "department" => %{
                 "type" => "choice",
                 "instructions" => "Which team should handle this?",
                 "criteria" => %{
                   "billing" => "Payments, invoicing, refunds",
                   "technical" => "Bugs, outages, integrations",
                   "sales" => nil
                 }
               },
               "frustration" => %{
                 "type" => "score",
                 "instructions" => "How frustrated is the customer?",
                 "criteria" => ["Calm", "Frustrated", "Very angry"]
               },
               "is_urgent" => %{
                 "type" => "noul",
                 "instructions" => "Does this convey urgency?",
                 "criteria" => %{"true" => "Explicitly time-sensitive", "false" => "No urgency expressed"}
               }
             }

      assert response.model == "jev-1.13.0"
      assert response.request_id == request_id()
      assert response.usage == %Usage{input_tokens: 414, output_tokens: 73}
      assert response.raw == systemone_body()

      assert response.answers == %{
               is_urgent: %Answer.Noul{noul: 0.95},
               department: %Answer.Choice{
                 choice: :billing,
                 probabilities: %{billing: 0.86, sales: 0.0, technical: 0.14},
                 confidence: 0.78
               },
               frustration: %Answer.Score{
                 score: 1.05,
                 legend: %{0 => "Calm", 1 => "Frustrated", 2 => "Very angry"},
                 probabilities: %{0 => 0.0, 1 => 0.95, 2 => 0.05},
                 confidence: 0.93
               }
             }
    end

    test "string question ids and Choice options come back as strings" do
      body = %{
        "model" => "jev-1.13.0",
        "answers" => %{
          "tone" => %{
            "type" => "choice",
            "choice" => "angry",
            "confidence" => 0.6,
            "probabilities" => %{"calm" => 0.2, "angry" => 0.8}
          }
        }
      }

      capture_requests(&json(&1, 200, body))
      questions = %{"tone" => TypeSafe.choice("What is the tone?", ["calm", "angry"])}

      assert {:ok, %Response{answers: answers}} = TypeSafe.ask(client(), "Fix it now.", questions)

      assert answers == %{
               "tone" => %Answer.Choice{
                 choice: "angry",
                 probabilities: %{"calm" => 0.2, "angry" => 0.8},
                 confidence: 0.6
               }
             }

      assert %{"questions" => %{"tone" => %{"criteria" => %{"calm" => nil, "angry" => nil}}}} = receive_request().json
    end

    test "a keyword list of questions keeps its order on the wire" do
      body = %{
        "model" => "jev-1.13.0",
        "answers" => %{
          "zeta" => %{"type" => "noul", "noul" => 0.1},
          "alpha" => %{"type" => "noul", "noul" => 0.2},
          "mid" => %{"type" => "noul", "noul" => 0.3}
        }
      }

      capture_requests(&json(&1, 200, body))

      questions = [zeta: TypeSafe.noul("Z?"), alpha: TypeSafe.noul("A?"), mid: TypeSafe.noul("M?")]

      assert {:ok, %Response{answers: answers}} = TypeSafe.ask(client(), "state", questions)
      assert answers == %{zeta: %Answer.Noul{noul: 0.1}, alpha: %Answer.Noul{noul: 0.2}, mid: %Answer.Noul{noul: 0.3}}

      %{raw_body: raw} = receive_request()
      assert raw =~ ~s({"state":"state","model":"jev-latest","questions":{"zeta":)
      assert position(raw, ~s("zeta")) < position(raw, ~s("alpha"))
      assert position(raw, ~s("alpha")) < position(raw, ~s("mid"))
    end

    test "structured state is sent as JSON structure, never stringified" do
      capture_requests(&json(&1, 200, noul_body()))

      state = %{subject: "Refund", messages: [%{role: "user", text: "Charged twice"}], attempts: 3, vip: true}

      assert {:ok, _response} = TypeSafe.ask(client(), state, noul_question())

      assert receive_request().json["state"] == %{
               "subject" => "Refund",
               "messages" => [%{"role" => "user", "text" => "Charged twice"}],
               "attempts" => 3,
               "vip" => true
             }
    end

    test "a list state is sent as a JSON array" do
      capture_requests(&json(&1, 200, noul_body()))

      assert {:ok, _response} = TypeSafe.ask(client(), ["first message", %{"second" => 2}], noul_question())
      assert receive_request().json["state"] == ["first message", %{"second" => 2}]
    end

    test "uses the client's model unless the call passes :model" do
      capture_requests(&json(&1, 200, noul_body()))
      client = client(model: "jev-preview")

      assert {:ok, _response} = TypeSafe.ask(client, "state", noul_question())
      assert receive_request().json["model"] == "jev-preview"

      assert {:ok, _response} = TypeSafe.ask(client, "state", noul_question(), model: "jev-1.13.0")
      assert receive_request().json["model"] == "jev-1.13.0"
      assert client.model == "jev-preview"
    end

    test "per-call headers are merged over the client's headers" do
      capture_requests(&json(&1, 200, noul_body()))
      client = client(headers: %{"x-team" => "support", "x-trace-id" => "client"})

      assert {:ok, _response} =
               TypeSafe.ask(client, "state", noul_question(), headers: [{"X-Trace-Id", "call"}, {"x-call-only", 1}])

      headers = receive_request().headers
      assert headers["x-team"] == ["support"]
      assert headers["x-trace-id"] == ["call"]
      assert headers["x-call-only"] == ["1"]

      assert {:ok, _response} = TypeSafe.ask(client, "state", noul_question())
      headers = receive_request().headers
      assert headers["x-trace-id"] == ["client"]
      refute Map.has_key?(headers, "x-call-only")
    end

    test "per-call :timeout sets the receive timeout for that call only, never connect options" do
      capture_requests(&json(&1, 200, noul_body()))
      client = reporting_options(client(timeout: 5_000))

      assert {:ok, _response} = TypeSafe.ask(client, "state", noul_question(), timeout: 1_234)
      assert_received {:typesafe_options, %{receive_timeout: 1_234} = options}
      refute Map.has_key?(options, :connect_options)

      assert {:ok, _response} = TypeSafe.ask(client, "state", noul_question())
      assert_received {:typesafe_options, %{receive_timeout: 5_000} = options}
      refute Map.has_key?(options, :connect_options)
    end

    test "per-call :retry options enable retries on a client without them, over the defaults" do
      Req.Test.expect(TypeSafe, 2, &json(&1, 503, %{"detail" => "Service Unavailable"}))
      Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))
      client = client(retry: false)

      assert {:error, %Error{type: :server, status: 503}} = TypeSafe.ask(client, "state", noul_question())

      assert {:ok, %Response{}} =
               TypeSafe.ask(client, "state", noul_question(), retry: [max_retries: 1, backoff_initial_ms: 0])

      Req.Test.verify!(TypeSafe)
    end

    test "per-call :retry options merge over the client's policy" do
      client =
        reporting_options(client(retry: [max_retries: 4, backoff_initial_ms: 0, budget_ms: nil, statuses: [409]]))

      Req.Test.expect(TypeSafe, &json(&1, 409, %{"detail" => "Conflict"}))
      Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))

      assert {:ok, %Response{}} = TypeSafe.ask(client, "state", noul_question(), retry: [max_retries: 1])
      assert_received {:typesafe_options, %{max_retries: 1, retry: retry}}
      assert retry.(Req.new(), Req.Response.new(status: 409)) == {:delay, 0}
      assert retry.(Req.new(), Req.Response.new(status: 503)) == false
      Req.Test.verify!(TypeSafe)
    end

    test "a per-call policy struct or false replaces the client's policy" do
      client = reporting_options(client(retry: [max_retries: 4, backoff_initial_ms: 0, statuses: [409]]))

      Req.Test.expect(TypeSafe, &json(&1, 409, %{"detail" => "Conflict"}))
      policy = %TypeSafe.Retry{max_retries: 1, backoff_initial_ms: 0}

      assert {:error, %Error{status: 409}} = TypeSafe.ask(client, "state", noul_question(), retry: policy)
      assert_received {:typesafe_options, %{max_retries: 1}}

      Req.Test.expect(TypeSafe, &json(&1, 409, %{"detail" => "Conflict"}))
      assert {:error, %Error{status: 409}} = TypeSafe.ask(client, "state", noul_question(), retry: false)
      assert_received {:typesafe_options, %{retry: false}}
      Req.Test.verify!(TypeSafe)
    end

    test "an invalid per-call policy struct raises ArgumentError" do
      refute_network()

      assert_raise ArgumentError, ~r/invalid TypeSafe call options/, fn ->
        TypeSafe.ask(client(), "state", noul_question(), retry: %TypeSafe.Retry{jitter: 3})
      end
    end

    test "an API error comes back as a TypeSafe.Error describing the response" do
      body = %{
        "detail" => %{
          "error_type" => "authentication_error",
          "message" => "Cannot authenticate with the server. Please check your API key and try again."
        }
      }

      capture_requests(&json(&1, 401, body))

      assert {:error, %Error{} = error} = TypeSafe.ask(client(), "state", noul_question())
      assert error.type == :authentication
      assert error.status == 401
      assert error.message == "Cannot authenticate with the server. Please check your API key and try again."
      assert error.body == body
      assert error.request_id == request_id()
      assert error.endpoint == "POST https://api.typesafe.ai/v1/systemone"
      assert error.headers["x-typesafe-request-id"] == [request_id()]
      assert error.retry_after_ms == nil
    end

    test "a transport failure comes back as a TypeSafe.Error" do
      Req.Test.stub(TypeSafe, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Error{type: :transport, reason: :econnrefused, status: nil, request_id: nil} = error} =
               TypeSafe.ask(client(retry: false), "state", noul_question())

      assert error.endpoint == "POST https://api.typesafe.ai/v1/systemone"
    end
  end

  describe "ask/4 with invalid input" do
    setup do
      refute_network()
      :ok
    end

    test "empty questions return :invalid_request without a request" do
      for questions <- [%{}, []] do
        assert {:error, %Error{type: :invalid_request, path: ["questions"], status: nil} = error} =
                 TypeSafe.ask(client(), "state", questions)

        assert error.message == "at least one question is required"
        assert error.endpoint == nil
      end
    end

    test "an invalid question returns :invalid_request with the offending path" do
      questions = %{severity: %TypeSafe.Question.Score{instructions: "Rate it", criteria: ["Only one"]}}

      assert {:error, %Error{type: :invalid_request, path: ["questions", "severity", "criteria"], details: [_ | _]}} =
               TypeSafe.ask(client(), "state", questions)
    end

    test "a value that is not a question returns :invalid_request" do
      assert {:error, %Error{type: :invalid_request, path: ["questions", "a"], message: message}} =
               TypeSafe.ask(client(), "state", %{a: "Is this spam?"})

      assert message =~ "expected a TypeSafe question"
    end

    test "questions that are neither a map nor a list return :invalid_request" do
      assert {:error, %Error{type: :invalid_request, path: ["questions"]}} =
               TypeSafe.ask(client(), "state", "Is this spam?")
    end

    test "duplicate question ids return :invalid_request" do
      questions = [a: TypeSafe.noul("One?"), a: TypeSafe.noul("Two?")]

      assert {:error, %Error{type: :invalid_request, path: ["questions", "a"], message: message}} =
               TypeSafe.ask(client(), "state", questions)

      assert message =~ "duplicate question id"
    end

    test "an unsupported state returns :invalid_request" do
      for state <- [nil, :atom, 42, {:tuple}] do
        assert {:error, %Error{type: :invalid_request, path: ["state"]}} =
                 TypeSafe.ask(client(), state, noul_question())
      end
    end
  end

  describe "ask/4 with an invalid 2xx body" do
    test "a non-JSON body returns :invalid_response" do
      capture_requests(&text(&1, 200, "<html>upstream proxy page</html>"))

      assert {:error, %Error{type: :invalid_response, path: [], status: 200} = error} =
               TypeSafe.ask(client(), "state", noul_question())

      assert error.message =~ "expected a JSON object response body"
      assert error.body == "<html>upstream proxy page</html>"
    end

    test ":invalid_response carries the status, request id, endpoint, headers and body" do
      body = noul_body("is_urgent", 7)
      capture_requests(&json(&1, 200, body))

      assert {:error, %Error{type: :invalid_response} = error} = TypeSafe.ask(client(), "state", noul_question())
      assert error.status == 200
      assert error.request_id == request_id()
      assert error.endpoint == "POST https://api.typesafe.ai/v1/systemone"
      assert error.headers["x-typesafe-request-id"] == [request_id()]
      assert error.body == body
      assert error.path == ["answers", "is_urgent", "noul"]

      assert Exception.message(error) =~
               "[endpoint: POST https://api.typesafe.ai/v1/systemone, request_id: #{request_id()}]"
    end

    test "a malformed body served as application/json returns :invalid_response with its status" do
      capture_requests(&bad_json(&1, 200))

      assert {:error, %Error{type: :invalid_response, status: 200, request_id: "req_bad_json"} = error} =
               TypeSafe.ask(client(), "state", noul_question())

      assert error.body == "<html>Bad gateway</html>"
    end

    test "an empty body returns :invalid_response" do
      capture_requests(&Plug.Conn.send_resp(&1, 200, ""))

      assert {:error, %Error{type: :invalid_response}} = TypeSafe.ask(client(), "state", noul_question())
    end

    test "a JSON array body returns :invalid_response" do
      capture_requests(&json(&1, 200, [noul_body()]))

      assert {:error, %Error{type: :invalid_response}} = TypeSafe.ask(client(), "state", noul_question())
    end

    test "a body without answers returns :invalid_response at answers" do
      capture_requests(&json(&1, 200, %{"model" => "jev-1.13.0"}))

      assert {:error, %Error{type: :invalid_response, path: ["answers"]}} =
               TypeSafe.ask(client(), "state", noul_question())
    end

    test "an out-of-range probability returns :invalid_response at the answer field" do
      capture_requests(&json(&1, 200, noul_body("is_urgent", 1.5)))

      assert {:error, %Error{type: :invalid_response, path: ["answers", "is_urgent", "noul"]} = error} =
               TypeSafe.ask(client(), "state", noul_question())

      assert Exception.message(error) =~ "at answers.is_urgent.noul"
    end

    test "invalid 2xx bodies are not retried" do
      Req.Test.expect(TypeSafe, &json(&1, 200, %{"model" => "jev-1.13.0"}))

      assert {:error, %Error{type: :invalid_response}} = TypeSafe.ask(client(), "state", noul_question())
      Req.Test.verify!(TypeSafe)
    end
  end

  describe "ask/4 with a malformed error body" do
    test "an HTML 502 served as application/json is a retried :server error with the text body" do
      Req.Test.expect(TypeSafe, 3, &bad_json(&1, 502))

      assert {:error, %Error{type: :server, status: 502} = error} = TypeSafe.ask(client(), "state", noul_question())
      assert error.body == "<html>Bad gateway</html>"
      assert error.message == "<html>Bad gateway</html>"
      assert error.request_id == "req_bad_json"
      Req.Test.verify!(TypeSafe)
    end

    test "with retry: false it is returned after one attempt" do
      Req.Test.expect(TypeSafe, &bad_json(&1, 500))

      assert {:error, %Error{type: :server, status: 500, body: "<html>Bad gateway</html>"}} =
               TypeSafe.ask(client(retry: false), "state", noul_question())

      Req.Test.verify!(TypeSafe)
    end
  end

  describe "ask!/4" do
    test "returns the response on success" do
      capture_requests(&json(&1, 200, noul_body()))

      assert %Response{answers: %{is_urgent: %Answer.Noul{noul: 0.95}}} =
               TypeSafe.ask!(client(), "state", noul_question())
    end

    test "raises the TypeSafe.Error on an API error" do
      body = %{"detail" => %{"error_type" => "api_usage_error", "message" => "Unknown model: nope"}}
      capture_requests(&json(&1, 400, body))

      error =
        assert_raise Error, fn ->
          TypeSafe.ask!(client(), "state", noul_question(), model: "nope")
        end

      assert error.type == :bad_request

      assert Exception.message(error) ==
               "bad_request (HTTP 400): Unknown model: nope " <>
                 "[endpoint: POST https://api.typesafe.ai/v1/systemone, request_id: #{request_id()}]"
    end

    test "raises :invalid_request without a request" do
      refute_network()

      assert_raise Error, "invalid_request: at least one question is required at questions", fn ->
        TypeSafe.ask!(client(), "state", %{})
      end
    end
  end

  describe "list_models/2" do
    test "gets /v1/models and decodes the models in order" do
      capture_requests(&json(&1, 200, models_body()))

      assert {:ok, models} = TypeSafe.list_models(client())

      assert models == [
               %Model{
                 name: "jev-latest",
                 description: "The latest iteration of TypeSafe's System One Model: Jev",
                 release_date: "2026-09-10T18:38:01.391457+00:00"
               },
               %Model{
                 name: "jev-preview",
                 description: "A preview version of `jev-latest`: should be better in most ways",
                 release_date: "2026-09-10T18:39:06.057655+00:00"
               }
             ]

      request = receive_request()
      assert request.method == "GET"
      assert request.path == "/v1/models"
      assert request.raw_body == ""
      assert request.headers["authorization"] == ["Bearer ts_test_key"]
      assert request.headers["x-typesafe-sdk"] == [Client.sdk()]
      refute Map.has_key?(request.headers, "content-type")
    end

    test "an empty model list decodes to []" do
      capture_requests(&json(&1, 200, %{"models" => []}))

      assert TypeSafe.list_models(client()) == {:ok, []}
    end

    test "accepts per-call headers, timeout and retry" do
      Req.Test.expect(TypeSafe, &json(&1, 503, %{"detail" => "Service Unavailable"}))
      Req.Test.expect(TypeSafe, reporting(self(), &json(&1, 200, models_body())))
      client = reporting_options(client(retry: false))

      assert {:ok, [_, _]} =
               TypeSafe.list_models(client,
                 headers: %{"x-call" => "yes"},
                 timeout: 2_000,
                 retry: [max_retries: 1, backoff_initial_ms: 0]
               )

      assert receive_request().headers["x-call"] == ["yes"]
      assert_received {:typesafe_options, %{receive_timeout: 2_000}}
      Req.Test.verify!(TypeSafe)
    end

    test "an API error comes back as a TypeSafe.Error for GET /v1/models" do
      capture_requests(&json(&1, 403, %{"detail" => %{"message" => "Must supply an API key!"}}))

      assert {:error, %Error{type: :permission_denied, status: 403} = error} = TypeSafe.list_models(client())
      assert error.endpoint == "GET https://api.typesafe.ai/v1/models"
      assert error.message == "Must supply an API key!"
    end

    test "a body without a models list returns :invalid_response" do
      for body <- [%{"models" => "jev-latest"}, %{"data" => []}] do
        capture_requests(&json(&1, 200, body))

        assert {:error, %Error{type: :invalid_response, path: ["models"]}} = TypeSafe.list_models(client())
      end
    end

    test "an invalid model entry returns :invalid_response with its index" do
      body = %{"models" => [hd(models_body()["models"]), %{"name" => 42, "description" => "", "release_date" => ""}]}
      capture_requests(&json(&1, 200, body))

      assert {:error, %Error{type: :invalid_response, path: ["models", "1" | _]}} = TypeSafe.list_models(client())
    end

    test "a non-JSON body returns :invalid_response" do
      capture_requests(&text(&1, 200, "not json"))

      assert {:error, %Error{type: :invalid_response}} = TypeSafe.list_models(client())
    end

    test ":invalid_response carries the status, request id, endpoint, headers and body" do
      body = %{"models" => [%{"name" => 42}]}
      capture_requests(&json(&1, 200, body))

      assert {:error, %Error{type: :invalid_response, path: ["models", "0" | _]} = error} =
               TypeSafe.list_models(client())

      assert error.status == 200
      assert error.request_id == request_id()
      assert error.endpoint == "GET https://api.typesafe.ai/v1/models"
      assert error.headers["x-typesafe-request-id"] == [request_id()]
      assert error.body == body
    end
  end

  describe "call options" do
    setup do
      refute_network()
      :ok
    end

    test "invalid transport option values raise before questions are validated" do
      assert_raise ArgumentError, ~r/invalid TypeSafe call options/, fn ->
        TypeSafe.ask(client(), "state", %{}, timeout: -1)
      end

      assert_raise ArgumentError, ~r/invalid TypeSafe call options/, fn ->
        TypeSafe.list_models(client(), retry: :sometimes)
      end
    end

    test "unknown ask/4 options raise ArgumentError" do
      assert_raise ArgumentError, ~r/unknown options \[:stream\] for TypeSafe.ask\/4/, fn ->
        TypeSafe.ask(client(), "state", noul_question(), stream: true)
      end
    end

    test "unknown list_models/2 options raise ArgumentError, including :model" do
      assert_raise ArgumentError, ~r/unknown options \[:model\] for TypeSafe.list_models\/2/, fn ->
        TypeSafe.list_models(client(), model: "jev-latest")
      end
    end

    test "options that are not a keyword list raise ArgumentError" do
      assert_raise ArgumentError, ~r/expects options as a keyword list/, fn ->
        TypeSafe.ask(client(), "state", noul_question(), [:retry])
      end

      assert_raise ArgumentError, ~r/expects options as a keyword list/, fn ->
        TypeSafe.list_models(client(), [{"timeout", 1}])
      end
    end

    test ":model must be a non-empty string" do
      for model <- ["", nil, :jev, 1] do
        assert_raise ArgumentError, ~r/:model must be a non-empty string/, fn ->
          TypeSafe.ask(client(), "state", noul_question(), model: model)
        end
      end
    end

    test ":telemetry_metadata must be a map" do
      assert_raise ArgumentError, ~r/:telemetry_metadata must be a map/, fn ->
        TypeSafe.ask(client(), "state", noul_question(), telemetry_metadata: [team: :support])
      end
    end

    test "invalid :timeout, :retry and :headers values raise ArgumentError" do
      for opts <- [[timeout: 0], [timeout: "1s"], [retry: :always], [retry: [max_retries: -1]], [headers: "x-a: 1"]] do
        assert_raise ArgumentError, ~r/invalid TypeSafe call options/, fn ->
          TypeSafe.ask(client(), "state", noul_question(), opts)
        end

        assert_raise ArgumentError, ~r/invalid TypeSafe call options/, fn ->
          TypeSafe.list_models(client(), opts)
        end
      end
    end
  end

  describe "processes" do
    test "a Task started by the test process uses the test's stub" do
      capture_requests(&json(&1, 200, noul_body()))
      client = client()

      task = Task.async(fn -> TypeSafe.ask(client, "state", noul_question()) end)

      assert {:ok, %Response{}} = Task.await(task)
    end

    test "Req.Test.allow/3 lets an unrelated process use the test's stub" do
      capture_requests(&json(&1, 200, noul_body()))
      client = client()
      test_pid = self()

      pid =
        spawn(fn ->
          receive do
            :go -> send(test_pid, {:result, TypeSafe.ask(client, "state", noul_question())})
          end
        end)

      :ok = Req.Test.allow(TypeSafe, test_pid, pid)
      send(pid, :go)

      assert_receive {:result, {:ok, %Response{answers: %{is_urgent: %Answer.Noul{noul: 0.95}}}}}, 1_000
    end

    test "a process that was not allowed cannot see the test's stub" do
      capture_requests(&json(&1, 200, noul_body()))
      client = client()
      test_pid = self()

      spawn(fn ->
        result =
          try do
            TypeSafe.ask(client, "state", noul_question())
          rescue
            exception in RuntimeError -> {:raised, Exception.message(exception)}
          end

        send(test_pid, {:result, result})
      end)

      assert_receive {:result, {:raised, message}}, 1_000
      assert message =~ "cannot find mock/stub TypeSafe"
    end

    test "one client is shared safely by concurrent calls" do
      Req.Test.stub(TypeSafe, fn conn ->
        %{"state" => state} = conn |> Req.Test.raw_body() |> IO.iodata_to_binary() |> JSON.decode!()
        json(conn, 200, noul_body("is_urgent", String.to_integer(state) / 100))
      end)

      client = client()

      results =
        1..20
        |> Task.async_stream(fn n -> {n, TypeSafe.ask(client, Integer.to_string(n), noul_question())} end,
          max_concurrency: 10
        )
        |> Enum.map(fn {:ok, result} -> result end)

      for {n, result} <- results do
        assert {:ok, %Response{answers: %{is_urgent: %Answer.Noul{noul: noul}}}} = result
        assert noul == n / 100
      end
    end
  end

  defp bad_json(conn, status) do
    conn
    |> Plug.Conn.put_resp_header("x-typesafe-request-id", "req_bad_json")
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, "<html>Bad gateway</html>")
  end

  defp position(haystack, needle) do
    {index, _length} = :binary.match(haystack, needle)
    index
  end
end
