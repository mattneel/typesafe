defmodule TypeSafe.ErrorTest do
  use ExUnit.Case, async: true

  import TypeSafe.TestHelpers, only: [client: 0, client: 1]
  import TypeSafe.TransportHelpers

  alias TypeSafe.Error
  alias TypeSafe.Retry

  @moduletag :capture_log

  @endpoint "POST https://api.typesafe.ai/v1/systemone"

  describe "HTTP status mapping" do
    @statuses %{
      400 => :bad_request,
      401 => :authentication,
      403 => :permission_denied,
      404 => :not_found,
      422 => :unprocessable,
      429 => :rate_limited,
      529 => :overloaded,
      500 => :server,
      501 => :server,
      502 => :server,
      503 => :server,
      504 => :server,
      520 => :server,
      599 => :server,
      402 => :api,
      405 => :api,
      408 => :api,
      409 => :api,
      410 => :api,
      413 => :api,
      418 => :api,
      451 => :api
    }

    for {status, type} <- @statuses do
      test "HTTP #{status} is :#{type}" do
        assert %Error{type: unquote(type), status: unquote(status)} = error_for(unquote(status), %{"detail" => "x"})
      end
    end

    test "every mapped type is a documented type" do
      assert @statuses |> Map.values() |> Enum.all?(&(&1 in Error.types()))
    end
  end

  describe "message extraction" do
    test "a top-level \"error\" string" do
      assert error_for(429, %{"error" => "rate limit exceeded"}).message == "rate limit exceeded"
    end

    test "an \"error\" object with a message" do
      assert error_for(500, %{"error" => %{"type" => "server_error", "message" => "nested failure"}}).message ==
               "nested failure"
    end

    test "a top-level \"message\" string" do
      assert error_for(503, %{"message" => "maintenance"}).message == "maintenance"
    end

    test "a \"detail\" string, as the live 404 sends" do
      error = error_for(404, %{"detail" => "Not Found"})

      assert error.message == "Not Found"
      assert error.body == %{"detail" => "Not Found"}
    end

    test "a \"detail\" object, as the live 401, 403 and 400 send" do
      bodies = %{
        401 => "Cannot authenticate with the server. Please check your API key and try again.",
        403 => "Must supply an API key! Check your request and try again.",
        400 => "Unknown model: nope"
      }

      for {status, message} <- bodies do
        body = %{"detail" => %{"error_type" => "authentication_error", "message" => message}}
        assert error_for(status, body).message == message
      end
    end

    test "a \"detail\" list of validation errors, as the live 422 sends" do
      body = %{
        "detail" => [
          %{
            "type" => "too_short",
            "loc" => ["body", "questions"],
            "msg" => "Dictionary should have at least 1 item after validation, not 0",
            "input" => %{},
            "ctx" => %{"field_type" => "Dictionary", "min_length" => 1, "actual_length" => 0}
          }
        ]
      }

      error = error_for(422, body)

      assert error.type == :unprocessable
      assert error.message == "questions: Dictionary should have at least 1 item after validation, not 0"
      assert error.body == body
    end

    test "several validation errors are joined with their locations" do
      body = %{
        "detail" => [
          %{"loc" => ["body", "questions", "tone", "type"], "msg" => "Input should be 'noul'"},
          %{"loc" => ["body", "questions", "levels", 0], "msg" => "Field required"},
          %{"loc" => ["body"], "msg" => "Invalid JSON"},
          %{"msg" => "No location"},
          %{"loc" => ["query", "debug"], "type" => "missing"}
        ]
      }

      assert error_for(422, body).message ==
               "questions.tone.type: Input should be 'noul'; questions.levels.0: Field required; " <>
                 "Invalid JSON; No location"
    end

    test ~s("error" wins over "message", which wins over "detail") do
      assert error_for(400, %{"error" => "e", "message" => "m", "detail" => "d"}).message == "e"
      assert error_for(400, %{"error" => 42, "message" => "m", "detail" => "d"}).message == "m"
      assert error_for(400, %{"error" => %{"code" => 7}, "detail" => "d"}).message == "d"
    end

    test "empty message strings are skipped" do
      assert error_for(404, %{"error" => "", "detail" => "Not Found"}).message == "Not Found"
      assert error_for(400, %{"error" => %{"message" => ""}, "message" => "m"}).message == "m"
      assert error_for(500, %{"message" => ""}).message == ~s({"message":""})
    end

    test "a JSON body without a message is rendered compactly" do
      assert error_for(500, %{"code" => 7}).message == ~s({"code":7})
      assert error_for(500, ["upstream", "failed"]).message == ~s(["upstream","failed"])
      assert error_for(400, %{"detail" => [%{"type" => "missing"}]}).message == ~s({"detail":[{"type":"missing"}]})
    end

    test "a long JSON body without a message is truncated to 200 characters" do
      body = %{"trace" => String.duplicate("x", 500)}
      message = error_for(500, body).message

      assert String.length(message) == 201
      assert message == String.slice(~s({"trace":") <> String.duplicate("x", 500), 0, 200) <> "…"
    end

    test "a plain-text body is the message" do
      error = error_for_text(502, "upstream connect error or disconnect/reset before headers")

      assert error.type == :server
      assert error.message == "upstream connect error or disconnect/reset before headers"
      assert error.body == "upstream connect error or disconnect/reset before headers"
    end

    test "a long plain-text body is truncated to 200 characters in the message but kept in the body" do
      html = "<html><body>" <> String.duplicate("Bad gateway. ", 40) <> "</body></html>"
      error = error_for_text(502, html)

      assert error.message == String.slice(html, 0, 200) <> "…"
      assert error.body == html
    end

    test "a body of exactly 200 characters is not truncated" do
      text = String.duplicate("é", 200)

      assert error_for_text(500, text).message == text
    end

    test "JSON sent with a non-JSON content type is still decoded" do
      error = error_for_text(401, ~s({"detail":{"message":"bad key"}}))

      assert error.message == "bad key"
      assert error.body == %{"detail" => %{"message" => "bad key"}}
    end

    test "an empty body reports the status" do
      Req.Test.stub(TypeSafe, &Plug.Conn.send_resp(&1, 503, ""))

      assert {:error, %Error{type: :server, message: "HTTP 503 with no body", body: nil}} =
               TypeSafe.ask(client(retry: false), "state", noul_question())
    end
  end

  describe "response fields" do
    test "keep the status, decoded body, headers, request id and endpoint" do
      body = %{"detail" => "Not Found"}
      Req.Test.stub(TypeSafe, &json(&1, 404, body, [{"x-extra", "1"}]))

      assert {:error, %Error{} = error} = TypeSafe.ask(client(), "state", noul_question())

      assert error.status == 404
      assert error.body == body
      assert error.request_id == request_id()
      assert error.endpoint == @endpoint
      assert error.headers["x-typesafe-request-id"] == [request_id()]
      assert error.headers["x-extra"] == ["1"]
      assert ["application/json" <> _] = error.headers["content-type"]
      assert error.path == nil
      assert error.details == nil
      assert error.reason == nil
    end

    test "an :invalid_response error carries the context of the 2xx response" do
      body = %{"model" => "jev-1.13.0"}
      Req.Test.stub(TypeSafe, &json(&1, 200, body, [{"x-extra", "1"}]))

      assert {:error, %Error{type: :invalid_response, path: ["answers"]} = error} =
               TypeSafe.ask(client(), "state", noul_question())

      assert error.status == 200
      assert error.body == body
      assert error.request_id == request_id()
      assert error.endpoint == @endpoint
      assert error.headers["x-extra"] == ["1"]
      assert Exception.message(error) =~ "invalid_response (HTTP 200): "
    end

    test "put_response/3 decodes the body and keeps the error's validation fields" do
      invalid = Error.invalid(:invalid_response, "expected a JSON object response body", [])
      headers = %{"x-typesafe-request-id" => ["req_put"]}

      for {raw, decoded} <- [{~s({"a":1}), %{"a" => 1}}, {%{"a" => 1}, %{"a" => 1}}, {"oops", "oops"}, {"", nil}] do
        response = Req.Response.new(status: 201, body: raw, headers: headers)

        assert %Error{} = error = Error.put_response(invalid, response, "GET https://api.typesafe.ai/v1/x")
        assert {error.status, error.request_id, error.headers, error.body} == {201, "req_put", headers, decoded}
        assert error.endpoint == "GET https://api.typesafe.ai/v1/x"

        assert {error.type, error.message, error.path, error.details} ==
                 {:invalid_response, invalid.message, [], invalid.details}
      end
    end

    test "a malformed JSON error body is kept as text, not reported as a transport error" do
      Req.Test.stub(TypeSafe, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, ~s({"detail": "unterminated))
      end)

      assert %Error{type: :server, status: 503, body: ~s({"detail": "unterminated), reason: nil} = error_for_stubbed()
    end

    test "request_id is nil without the header" do
      Req.Test.stub(TypeSafe, &TypeSafe.TestHelpers.send_json(&1, 500, %{"detail" => "boom"}))

      assert %Error{request_id: nil} = error_for_stubbed()
    end

    test "the endpoint names the method and full URL" do
      Req.Test.stub(TypeSafe, &json(&1, 401, %{"detail" => "no"}))

      assert {:error, %Error{endpoint: "GET https://gateway.example.com/ts/v1/models"}} =
               TypeSafe.list_models(client(base_url: "https://gateway.example.com/ts/"))
    end
  end

  describe "retry_after_ms" do
    test "is set for :rate_limited from retry-after-ms" do
      assert %Error{type: :rate_limited, retry_after_ms: 1_200} =
               error_for(429, %{"detail" => "slow down"}, [{"retry-after-ms", "1200"}, {"retry-after", "2"}])
    end

    test "is set for :overloaded from Retry-After seconds" do
      assert %Error{type: :overloaded, retry_after_ms: 3_000} =
               error_for(529, %{"detail" => "Overloaded"}, [{"retry-after", "3"}])
    end

    test "is nil for :rate_limited without a usable header" do
      assert %Error{retry_after_ms: nil} = error_for(429, %{"detail" => "slow down"})
      assert %Error{retry_after_ms: nil} = error_for(429, %{"detail" => "slow down"}, [{"retry-after", "later"}])
    end

    test "is nil for every other status, even with the header" do
      for status <- [400, 408, 500, 503] do
        assert %Error{retry_after_ms: nil} = error_for(status, %{"detail" => "x"}, [{"retry-after-ms", "500"}])
      end
    end
  end

  describe "transport errors" do
    test ":timeout maps to type :timeout" do
      Req.Test.stub(TypeSafe, &Req.Test.transport_error(&1, :timeout))

      assert %Error{} = error = error_for_stubbed()
      assert error.type == :timeout
      assert error.reason == :timeout
      assert error.message == "timeout"
      assert error.status == nil
      assert error.body == nil
      assert error.headers == %{}
      assert error.request_id == nil
      assert error.retry_after_ms == nil
      assert error.endpoint == @endpoint
    end

    for {reason, message} <- [
          econnrefused: "connection refused",
          closed: "socket closed",
          nxdomain: "non-existing domain"
        ] do
      test "#{reason} maps to type :transport" do
        Req.Test.stub(TypeSafe, &Req.Test.transport_error(&1, unquote(reason)))

        assert %Error{type: :transport, reason: unquote(reason), message: unquote(message), status: nil} =
                 error_for_stubbed()
      end
    end

    test "other Req exceptions map to :transport with their reason" do
      exception = %Req.HTTPError{protocol: :http2, reason: :unprocessed}

      assert {:error, %Error{type: :transport, reason: :unprocessed, message: message}} =
               TypeSafe.Req.decode({:error, exception}, noul_question())

      assert message == Exception.message(exception)
    end

    test "an exception without a reason is kept as the reason" do
      exception = %RuntimeError{message: "adapter crashed"}

      assert {:error, %Error{type: :transport, reason: ^exception, message: "adapter crashed"}} =
               TypeSafe.Req.decode({:error, exception}, noul_question())
    end
  end

  describe "message/1" do
    test "renders type, status, message, endpoint and request id" do
      error = %Error{
        type: :bad_request,
        status: 400,
        message: "Unknown model: nope",
        endpoint: @endpoint,
        request_id: "req_1"
      }

      assert Exception.message(error) ==
               "bad_request (HTTP 400): Unknown model: nope [endpoint: #{@endpoint}, request_id: req_1]"
    end

    test "omits the parts that are nil" do
      assert Exception.message(%Error{type: :server, status: 500, message: "boom"}) == "server (HTTP 500): boom"

      assert Exception.message(%Error{type: :timeout, message: "timeout", endpoint: @endpoint}) ==
               "timeout: timeout [endpoint: #{@endpoint}]"

      assert Exception.message(%Error{type: :rate_limited, status: 429, message: "slow", request_id: "req_2"}) ==
               "rate_limited (HTTP 429): slow [request_id: req_2]"
    end

    test "includes the path of a validation error" do
      error = %Error{
        type: :invalid_request,
        message: "score criteria needs at least two levels",
        path: ["questions", "a", "criteria"]
      }

      assert Exception.message(error) ==
               "invalid_request: score criteria needs at least two levels at questions.a.criteria"

      assert Exception.message(%{error | path: []}) == "invalid_request: score criteria needs at least two levels"
    end

    test "falls back to a default message per type" do
      assert Exception.message(%Error{type: :invalid_request}) == "invalid_request: invalid request"
      assert Exception.message(%Error{type: :invalid_response}) == "invalid_response: invalid response"
      assert Exception.message(%Error{type: :timeout}) == "timeout: request timed out"
      assert Exception.message(%Error{type: :transport}) == "transport: transport error"
      assert Exception.message(%Error{type: :server, status: 500}) == "server (HTTP 500): request failed (server)"
    end

    test "is what raising the error shows" do
      assert_raise Error, "overloaded (HTTP 529): Overloaded [request_id: req_3]", fn ->
        raise Error, type: :overloaded, status: 529, message: "Overloaded", request_id: "req_3"
      end
    end

    test "renders a real API error in one line" do
      body = %{"detail" => %{"error_type" => "authentication_error", "message" => "Cannot authenticate."}}

      assert Exception.message(error_for(401, body)) ==
               "authentication (HTTP 401): Cannot authenticate. [endpoint: #{@endpoint}, request_id: #{request_id()}]"
    end
  end

  describe "retryable?/2" do
    test "matches the default policy" do
      retryable = [
        %Error{type: :rate_limited, status: 429},
        %Error{type: :overloaded, status: 529},
        %Error{type: :server, status: 500},
        %Error{type: :server, status: 503},
        %Error{type: :api, status: 408},
        %Error{type: :transport, reason: :econnrefused},
        %Error{type: :timeout, reason: :timeout}
      ]

      not_retryable = [
        %Error{type: :bad_request, status: 400},
        %Error{type: :authentication, status: 401},
        %Error{type: :permission_denied, status: 403},
        %Error{type: :not_found, status: 404},
        %Error{type: :api, status: 409},
        %Error{type: :unprocessable, status: 422},
        %Error{type: :invalid_request},
        %Error{type: :invalid_response}
      ]

      for error <- retryable, do: assert(Error.retryable?(error), "expected #{inspect(error)} to be retryable")
      for error <- not_retryable, do: refute(Error.retryable?(error), "expected #{inspect(error)} not to be retryable")
    end

    test "follows a custom policy" do
      policy = Retry.new(statuses: [409], retry_transport_errors: false)

      assert Error.retryable?(%Error{type: :api, status: 409}, policy)
      refute Error.retryable?(%Error{type: :server, status: 503}, policy)
      refute Error.retryable?(%Error{type: :transport, reason: :closed}, policy)
      refute Error.retryable?(%Error{type: :timeout, reason: :timeout}, policy)
    end

    test "works on errors returned by a call" do
      assert Error.retryable?(error_for(429, %{"detail" => "slow down"}))
      refute Error.retryable?(error_for(401, %{"detail" => "no"}))
    end
  end

  describe "types/0" do
    test "lists every type once, in the documented order" do
      assert Error.types() == [
               :invalid_request,
               :bad_request,
               :authentication,
               :permission_denied,
               :not_found,
               :unprocessable,
               :rate_limited,
               :overloaded,
               :server,
               :api,
               :transport,
               :timeout,
               :invalid_response
             ]
    end
  end

  defp error_for(status, body, headers \\ []) do
    Req.Test.stub(TypeSafe, &json(&1, status, body, headers))
    error_for_stubbed()
  end

  defp error_for_text(status, body) do
    Req.Test.stub(TypeSafe, &text(&1, status, body, [{"x-typesafe-request-id", request_id()}]))
    error_for_stubbed()
  end

  defp error_for_stubbed do
    assert {:error, %Error{} = error} = TypeSafe.ask(client(retry: false), "state", noul_question())
    error
  end
end
