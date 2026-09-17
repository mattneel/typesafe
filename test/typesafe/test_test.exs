defmodule TypeSafe.TestTest do
  use ExUnit.Case, async: true

  import TypeSafe.TestHelpers, only: [client: 0, client: 1]
  import TypeSafe.TransportHelpers, only: [questions: 0, noul_question: 0]

  alias TypeSafe.Answer
  alias TypeSafe.Error
  alias TypeSafe.Model
  alias TypeSafe.Response
  alias TypeSafe.Test, as: Stubs
  alias TypeSafe.Usage

  @moduletag :capture_log

  @legend ["Calm", "Frustrated", "Very angry"]

  describe "stub_answers/2" do
    test "the documented example decodes into answers keyed like the questions" do
      assert :ok =
               Stubs.stub_answers(%{
                 department: {:choice, :technical, %{billing: 0.08, technical: 0.85, sales: 0.07}, 0.82},
                 is_urgent: {:noul, 0.92},
                 frustration: {:score, 1.6, @legend, %{0 => 0.05, 1 => 0.3, 2 => 0.65}, 0.78}
               })

      assert {:ok, %Response{answers: answers}} = TypeSafe.ask(client(), "Help!", questions())

      assert answers == %{
               department: %Answer.Choice{
                 choice: :technical,
                 probabilities: %{billing: 0.08, technical: 0.85, sales: 0.07},
                 confidence: 0.82
               },
               is_urgent: %Answer.Noul{noul: 0.92},
               frustration: %Answer.Score{
                 score: 1.6,
                 legend: %{0 => "Calm", 1 => "Frustrated", 2 => "Very angry"},
                 probabilities: %{0 => 0.05, 1 => 0.3, 2 => 0.65},
                 confidence: 0.78
               }
             }
    end

    test "confidence defaults to the top probability" do
      Stubs.stub_answers(%{
        department: {:choice, :billing, %{billing: 0.6, technical: 0.3, sales: 0.1}},
        is_urgent: {:noul, 0.1},
        frustration: {:score, 0.4, @legend, %{0 => 0.7, 1 => 0.2, 2 => 0.1}}
      })

      assert {:ok, %Response{answers: answers}} = TypeSafe.ask(client(), "state", questions())
      assert answers.department.confidence == 0.6
      assert answers.frustration.confidence == 0.7
    end

    test "a Score legend may be a map of level index to level" do
      Stubs.stub_answers(%{severity: {:score, 0.4, %{0 => "Low", "1" => "High"}, %{0 => 0.6, 1 => 0.4}, 0.2}})

      assert {:ok, %Response{answers: %{severity: answer}}} =
               TypeSafe.ask(client(), "state", %{severity: TypeSafe.score("Severity?", ["Low", "High"])})

      assert answer == %Answer.Score{
               score: 0.4,
               legend: %{0 => "Low", 1 => "High"},
               probabilities: %{0 => 0.6, 1 => 0.4},
               confidence: 0.2
             }
    end

    test "answer structs round-trip unchanged" do
      stubbed = %{
        is_urgent: %Answer.Noul{noul: 0.3},
        department: %Answer.Choice{
          choice: :sales,
          probabilities: %{billing: 0.1, technical: 0.2, sales: 0.7},
          confidence: 0.5
        },
        frustration: %Answer.Score{
          score: 0.5,
          legend: %{0 => "Calm", 1 => "Frustrated", 2 => "Very angry"},
          probabilities: %{0 => 0.5, 1 => 0.5, 2 => 0.0},
          confidence: 0.4
        }
      }

      Stubs.stub_answers(stubbed)

      assert {:ok, %Response{answers: ^stubbed}} = TypeSafe.ask(client(), "state", questions())
    end

    test "accepts a keyword list and string ids, matching questions by their wire id" do
      Stubs.stub_answers(tone: {:choice, "angry", %{"calm" => 0.25, "angry" => 0.75}})

      assert {:ok, %Response{answers: answers}} =
               TypeSafe.ask(client(), "state", %{"tone" => TypeSafe.choice("Tone?", ["calm", "angry"])})

      assert answers == %{
               "tone" => %Answer.Choice{
                 choice: "angry",
                 probabilities: %{"calm" => 0.25, "angry" => 0.75},
                 confidence: 0.75
               }
             }
    end

    test "reports the model, usage and request id" do
      Stubs.stub_answers(%{is_urgent: {:noul, 0.5}},
        model: "jev-1.13.0",
        usage: %{input_tokens: 120, output_tokens: 8},
        request_id: "req_stubbed"
      )

      assert {:ok, %Response{} = response} = TypeSafe.ask(client(), "state", noul_question())
      assert response.model == "jev-1.13.0"
      assert response.usage == %Usage{input_tokens: 120, output_tokens: 8}
      assert response.request_id == "req_stubbed"
    end

    test "defaults to jev-latest, zero usage and a generated request id" do
      Stubs.stub_answers(%{is_urgent: {:noul, 0.5}})

      assert {:ok, %Response{} = first} = TypeSafe.ask(client(), "state", noul_question())
      assert {:ok, %Response{} = second} = TypeSafe.ask(client(), "state", noul_question())

      assert first.model == "jev-latest"
      assert first.usage == %Usage{input_tokens: 0, output_tokens: 0}
      assert "req_test_" <> _ = first.request_id
      assert first.request_id != second.request_id
    end

    test "raises ExUnit.AssertionError when the sent ids differ from the stubbed ids" do
      Stubs.stub_answers(%{is_urgent: {:noul, 0.5}, tone: {:choice, :calm, %{calm: 1.0}}})
      questions = %{is_urgent: TypeSafe.noul("Urgent?"), topic: TypeSafe.noul("About billing?")}

      error = assert_raise ExUnit.AssertionError, fn -> TypeSafe.ask(client(), "state", questions) end

      assert error.message =~ "the question ids sent do not match the stubbed answers"
      assert error.message =~ ~s(sent but not stubbed: ["topic"])
      assert error.message =~ ~s(stubbed but not sent: ["tone"])
    end

    test "raises ExUnit.AssertionError when a question's type differs from its stubbed answer" do
      Stubs.stub_answers(%{is_urgent: {:choice, :yes, %{yes: 0.9, no: 0.1}}})

      error = assert_raise ExUnit.AssertionError, fn -> TypeSafe.ask(client(), "state", noul_question()) end

      assert error.message == ~s(TypeSafe.Test: question "is_urgent" was sent as "noul" but stubbed as "choice")
    end

    test "raises ExUnit.AssertionError for a request other than POST /v1/systemone" do
      Stubs.stub_answers(%{is_urgent: {:noul, 0.5}})

      error = assert_raise ExUnit.AssertionError, fn -> TypeSafe.list_models(client()) end

      assert error.message =~ "expected POST /v1/systemone, got GET /v1/models"
      assert error.message =~ "Use TypeSafe.Test.stub_models/2"
    end

    test "raises ExUnit.AssertionError for a request without questions" do
      Stubs.stub_answers(%{is_urgent: {:noul, 0.5}})

      assert_raise ExUnit.AssertionError, ~r/without a JSON "questions" object/, fn ->
        TypeSafe.Client.request(client(), method: :post, url: "/v1/systemone", json: %{state: "hi"})
      end
    end

    test "raises ArgumentError for an invalid answer spec when stubbing" do
      for spec <- [{:noul, "high"}, {:choice, :a, [a: 1.0]}, {:score, "1", @legend, %{}}, {:unknown, 1}, 0.5] do
        assert_raise ArgumentError, ~r/invalid stubbed answer for :is_urgent/, fn ->
          Stubs.stub_answers(%{is_urgent: spec})
        end
      end

      assert_raise ArgumentError, ~r/expected \{question_id, answer\} pairs/, fn ->
        Stubs.stub_answers([{:is_urgent, {:noul, 0.1}}, :oops])
      end
    end
  end

  describe "stub_error/2" do
    test "defaults the body to the status reason phrase" do
      Stubs.stub_error(429)

      assert {:error, %Error{type: :rate_limited, status: 429} = error} = ask()
      assert error.message == "Too Many Requests"
      assert error.body == %{"detail" => "Too Many Requests"}
      assert "req_test_" <> _ = error.request_id
      assert error.retry_after_ms == nil
    end

    test "uses Overloaded for 529 and a generic phrase for unknown statuses" do
      Stubs.stub_error(529)
      assert {:error, %Error{type: :overloaded, message: "Overloaded"}} = ask()

      Stubs.stub_error(599)
      assert {:error, %Error{type: :server, message: "HTTP 599"}} = ask()
    end

    test "sends a map :body as JSON and a string :body as text" do
      Stubs.stub_error(422, body: %{"detail" => [%{"loc" => ["body", "questions"], "msg" => "Field required"}]})
      assert {:error, %Error{type: :unprocessable, message: "questions: Field required"}} = ask()

      Stubs.stub_error(502, body: "Bad gateway")
      assert {:error, %Error{type: :server, message: "Bad gateway", body: "Bad gateway"} = error} = ask()
      assert ["text/plain" <> _] = error.headers["content-type"]
    end

    test ":retry_after_ms sets both retry headers" do
      Stubs.stub_error(429, retry_after_ms: 1_200)

      assert {:error, %Error{retry_after_ms: 1_200} = error} = ask()
      assert error.headers["retry-after-ms"] == ["1200"]
      assert error.headers["retry-after"] == ["2"]
    end

    test ":headers and :request_id are sent with the response" do
      Stubs.stub_error(403, headers: %{"X-Ratelimit-Remaining" => 0}, request_id: "req_forbidden")

      assert {:error, %Error{type: :permission_denied, request_id: "req_forbidden"} = error} = ask()
      assert error.headers["x-ratelimit-remaining"] == ["0"]

      Stubs.stub_error(403, headers: [{"x-trace", "abc"}])
      assert {:error, %Error{} = error} = ask()
      assert error.headers["x-trace"] == ["abc"]
    end

    test "fails every TypeSafe request, including list_models" do
      Stubs.stub_error(401)

      assert {:error, %Error{type: :authentication, endpoint: "GET https://api.typesafe.ai/v1/models"}} =
               TypeSafe.list_models(client(retry: false))
    end
  end

  describe "stub_transport_error/2" do
    test ":timeout comes back as a :timeout error" do
      Stubs.stub_transport_error(:timeout)

      assert {:error, %Error{type: :timeout, reason: :timeout}} = ask()
    end

    test "other reasons come back as :transport errors" do
      Stubs.stub_transport_error(:econnrefused)

      assert {:error, %Error{type: :transport, reason: :econnrefused}} = ask()
      assert {:error, %Error{type: :transport, reason: :econnrefused}} = TypeSafe.list_models(client(retry: false))
    end
  end

  describe "stub_models/2" do
    test "accepts Model structs and maps with atom or string keys" do
      Stubs.stub_models([
        %Model{name: "jev-latest", description: "Latest", release_date: "2026-09-10T18:38:01Z"},
        %{name: "jev-preview", description: "Preview"},
        %{"name" => "jev-1.13.0"}
      ])

      assert {:ok, models} = TypeSafe.list_models(client())

      assert models == [
               %Model{name: "jev-latest", description: "Latest", release_date: "2026-09-10T18:38:01Z"},
               %Model{name: "jev-preview", description: "Preview", release_date: "2026-01-01"},
               %Model{name: "jev-1.13.0", description: "", release_date: "2026-01-01"}
             ]
    end

    test "sends the :request_id header" do
      Stubs.stub_models([%{name: "jev-latest"}], request_id: "req_models")

      assert {:ok, response} = TypeSafe.Client.request(client(), url: "/v1/models")
      assert response.headers["x-typesafe-request-id"] == ["req_models"]
    end

    test "raises ArgumentError for a model without a name" do
      assert_raise ArgumentError, ~r/stubbed model is missing :name/, fn ->
        Stubs.stub_models([%{description: "No name"}])
      end
    end

    test "raises ExUnit.AssertionError for a request other than GET /v1/models" do
      Stubs.stub_models([%{name: "jev-latest"}])

      assert_raise ExUnit.AssertionError, ~r"expected GET /v1/models, got POST /v1/systemone", fn -> ask() end
    end
  end

  describe "composing plugs" do
    test "error_plug/2 and answers_plug/2 script a retried call with Req.Test.expect/3" do
      Req.Test.expect(TypeSafe, Stubs.error_plug(529))
      Req.Test.expect(TypeSafe, Stubs.error_plug(429, retry_after_ms: 30))
      Req.Test.expect(TypeSafe, Stubs.answers_plug(%{is_urgent: {:noul, 0.9}}, request_id: "req_after_retries"))

      started = System.monotonic_time(:millisecond)

      assert {:ok, %Response{answers: %{is_urgent: %Answer.Noul{noul: 0.9}}, request_id: "req_after_retries"}} =
               TypeSafe.ask(client(), "state", noul_question())

      assert System.monotonic_time(:millisecond) - started >= 30
      Req.Test.verify!(TypeSafe)
    end

    test "models_plug/2 composes with a transport error" do
      Req.Test.expect(TypeSafe, &Req.Test.transport_error(&1, :closed))
      Req.Test.expect(TypeSafe, Stubs.models_plug([%{name: "jev-latest"}]))

      assert {:ok, [%Model{name: "jev-latest"}]} = TypeSafe.list_models(client())
      Req.Test.verify!(TypeSafe)
    end

    test "plugs work under any stub name, ignoring :name" do
      Req.Test.stub(:typesafe_plug_test, Stubs.answers_plug(%{is_urgent: {:noul, 0.2}}, name: TypeSafe))

      assert {:ok, %Response{answers: %{is_urgent: %Answer.Noul{noul: 0.2}}}} =
               TypeSafe.ask(named_client(:typesafe_plug_test), "state", noul_question())
    end
  end

  describe ":name" do
    test "installs every stub under a custom name" do
      client = named_client(MyApp.TypeSafeStub)

      Stubs.stub_answers(%{is_urgent: {:noul, 0.7}}, name: MyApp.TypeSafeStub)

      assert {:ok, %Response{answers: %{is_urgent: %Answer.Noul{noul: 0.7}}}} =
               TypeSafe.ask(client, "s", noul_question())

      Stubs.stub_error(404, name: MyApp.TypeSafeStub)
      assert {:error, %Error{type: :not_found}} = TypeSafe.ask(client, "s", noul_question())

      Stubs.stub_transport_error(:closed, name: MyApp.TypeSafeStub)
      assert {:error, %Error{type: :transport, reason: :closed}} = TypeSafe.ask(client, "s", noul_question())

      Stubs.stub_models([%{name: "jev-latest"}], name: MyApp.TypeSafeStub)
      assert {:ok, [%Model{name: "jev-latest"}]} = TypeSafe.list_models(client)
    end

    test "a stub under the default name does not serve a client using another name" do
      Stubs.stub_answers(%{is_urgent: {:noul, 0.7}})

      assert_raise RuntimeError, ~r/cannot find mock\/stub MyApp.OtherStub/, fn ->
        TypeSafe.ask(named_client(MyApp.OtherStub), "state", noul_question())
      end
    end
  end

  defp ask, do: TypeSafe.ask(client(retry: false), "state", noul_question())

  defp named_client(name), do: client(retry: false, req_options: [plug: {Req.Test, name}])
end
