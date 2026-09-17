defmodule TypeSafe.ResponseTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import TypeSafe.Assertions
  import TypeSafe.TestHelpers

  alias TypeSafe.Answer
  alias TypeSafe.Question
  alias TypeSafe.Response
  alias TypeSafe.Usage

  @request_id "req_01J8Z6Q4XYZ"

  describe "from_wire/3 with documented responses" do
    test "restores atom question ids and Choice options from the request" do
      body = fixture("responses/mixed.json")

      assert {:ok, response} = Response.from_wire(body, @request_id, prepared(documented_questions()))

      assert response == %Response{
               model: "jev-1.13.0",
               request_id: @request_id,
               raw: body,
               usage: %Usage{input_tokens: 312, output_tokens: 48},
               answers: %{
                 is_urgent: %Answer.Noul{noul: 0.92},
                 department: %Answer.Choice{
                   choice: :technical,
                   probabilities: %{billing: 0.08, technical: 0.85, sales: 0.07},
                   confidence: 0.82
                 },
                 frustration: %Answer.Score{
                   score: 1.6,
                   legend: %{0 => "Calm", 1 => "Frustrated", 2 => "Very angry"},
                   probabilities: %{0 => 0.05, 1 => 0.3, 2 => 0.65},
                   confidence: 0.78
                 }
               }
             }
    end

    test "restores string question ids and options as strings" do
      questions = %{"department" => TypeSafe.choice("Team?", ["billing", "technical", "sales"])}

      assert {:ok, %Response{answers: %{"department" => answer}}} =
               Response.from_wire(fixture("responses/choice.json"), nil, prepared(questions))

      assert answer.choice == "technical"
      assert answer.probabilities == %{"billing" => 0.08, "technical" => 0.85, "sales" => 0.07}
    end

    test "restores a mix of atom and string ids and options key by key" do
      questions = [
        {"department", TypeSafe.choice("Team?", [:billing, "technical", :sales])},
        {:is_urgent, TypeSafe.noul("Urgent?")},
        {"frustration", TypeSafe.score("Frustration?", ["Calm", "Frustrated", "Very angry"])}
      ]

      assert {:ok, %Response{answers: answers}} =
               Response.from_wire(fixture("responses/mixed.json"), nil, prepared(questions))

      assert answers |> Map.keys() |> Enum.sort_by(&to_string/1) == ["department", "frustration", :is_urgent]
      assert answers["department"].choice == "technical"
      assert answers["department"].probabilities == %{:billing => 0.08, "technical" => 0.85, :sales => 0.07}
    end

    test "keeps ids and options as strings without request lookups" do
      for prepared <- [%{ids: %{}, options: %{}}, %{}] do
        assert {:ok, %Response{answers: %{"department" => %Answer.Choice{choice: "technical"}}}} =
                 Response.from_wire(fixture("responses/choice.json"), nil, prepared)
      end

      assert {:ok, %Response{answers: %{"is_urgent" => %Answer.Noul{}}}} =
               Response.from_wire(fixture("responses/noul.json"), nil)
    end

    test "keeps an answer id the request did not send as a string" do
      assert {:ok, %Response{answers: answers}} =
               Response.from_wire(fixture("responses/mixed.json"), nil, prepared(is_urgent: TypeSafe.noul("Urgent?")))

      assert answers |> Map.keys() |> Enum.sort_by(&to_string/1) == ["department", "frustration", :is_urgent]
    end

    test "decodes the single-question documented responses" do
      for {name, id, module} <- [
            {"noul", :is_urgent, Answer.Noul},
            {"choice", :department, Answer.Choice},
            {"score", :frustration, Answer.Score}
          ] do
        questions = Keyword.take(documented_questions(), [id])

        assert {:ok, %Response{model: "jev-latest", answers: answers}} =
                 Response.from_wire(fixture("responses/#{name}.json"), nil, prepared(questions))

        assert [{^id, %^module{}}] = Map.to_list(answers)
      end
    end

    test "returns integer probabilities as floats" do
      questions = [
        is_spam: TypeSafe.noul("Spam?"),
        is_greeting: TypeSafe.noul("Greeting?"),
        tone: TypeSafe.choice("Tone?", [:calm, :angry]),
        urgency: TypeSafe.score("Urgency?", ["Can wait", "This week", "Today"])
      ]

      assert {:ok, %Response{answers: answers, usage: usage}} =
               Response.from_wire(fixture("responses/integer_probabilities.json"), nil, prepared(questions))

      assert {answers.is_spam.noul, answers.is_greeting.noul} === {1.0, 0.0}
      assert answers.tone.probabilities === %{calm: 1.0, angry: 0.0}
      assert answers.urgency.score === 2.0
      assert usage == %Usage{input_tokens: 120, output_tokens: 0}
    end

    test "ignores unknown fields in the body, answers and usage, and keeps them in raw" do
      body = fixture("responses/extra_fields.json")

      assert {:ok, response} = Response.from_wire(body, nil, prepared(documented_questions()))

      assert {:ok, documented} =
               Response.from_wire(fixture("responses/mixed.json"), nil, prepared(documented_questions()))

      assert response.answers == documented.answers
      assert response.usage == %Usage{input_tokens: 312, output_tokens: 48}
      assert response.raw["usage"]["cached_input_tokens"] == 100
      assert response.raw["answers"]["department"]["entropy"] == 0.51
    end
  end

  describe "from_wire/3 usage" do
    test "a missing or null usage decodes to nil counts" do
      body = fixture("responses/missing_usage.json")

      assert {:ok, %Response{usage: %Usage{input_tokens: nil, output_tokens: nil}}} = Response.from_wire(body, nil)
      assert {:ok, %Response{usage: %Usage{input_tokens: nil}}} = Response.from_wire(Map.put(body, "usage", nil), nil)
    end

    test "a count may be missing on its own" do
      body = Map.put(fixture("responses/missing_usage.json"), "usage", %{"input_tokens" => 312})

      assert {:ok, %Response{usage: %Usage{input_tokens: 312, output_tokens: nil}}} = Response.from_wire(body, nil)
    end

    test "rejects counts that are not non-negative integers" do
      body = fixture("responses/noul.json")

      for {value, message} <- [
            {"312", "invalid type: expected integer"},
            {312.5, "invalid type: expected integer"},
            {-1, "too small: must be at least 0"}
          ] do
        assert_invalid_response(
          Response.from_wire(put_in(body, ["usage", "input_tokens"], value), nil),
          ["usage", "input_tokens"],
          message
        )
      end
    end

    test "rejects a usage that is not an object" do
      assert_invalid_response(
        Response.from_wire(Map.put(fixture("responses/noul.json"), "usage", [312, 48]), nil),
        ["usage"],
        ~r/^invalid type/
      )
    end
  end

  describe "from_wire/3 with unknown answer types" do
    test "skips the answer with a warning and keeps it in raw" do
      body = fixture("responses/unknown_type.json")

      log =
        capture_log(fn ->
          assert {:ok, response} = Response.from_wire(body, nil, prepared(is_urgent: TypeSafe.noul("Urgent?")))
          assert response.answers == %{is_urgent: %Answer.Noul{noul: 0.92}}
          assert response.raw["answers"]["logo_region"]["type"] == "bounding_box"
        end)

      assert log =~ ~s(ignoring answer "logo_region" with unrecognized type "bounding_box")
    end
  end

  describe "from_wire/3 with invalid bodies" do
    test "rejects a body that is not a JSON object" do
      for body <- [nil, "Internal Server Error", ["answers"], 42, URI.parse("https://typesafe.ai")] do
        assert_invalid_response(
          Response.from_wire(body, @request_id),
          [],
          ~r/^expected a JSON object response body, got: /
        )
      end
    end

    test "requires model and answers" do
      assert_invalid_response(Response.from_wire(%{"answers" => %{}}, nil), ["model"], "is required")
      assert_invalid_response(Response.from_wire(%{"model" => "jev-latest"}, nil), ["answers"], "is required")

      assert {:error, error} = Response.from_wire(%{}, nil)

      assert error.details |> Enum.map(&{&1.code, &1.path}) |> Enum.sort() == [
               required: ["answers"],
               required: ["model"]
             ]
    end

    test "rejects a model that is not a string and answers that are not an object" do
      assert_invalid_response(
        Response.from_wire(%{"model" => 1, "answers" => %{}}, nil),
        ["model"],
        "invalid type: expected string"
      )

      assert_invalid_response(
        Response.from_wire(%{"model" => "m", "answers" => []}, nil),
        ["answers"],
        "invalid type: expected map"
      )
    end

    test "locates a malformed answer by its wire id" do
      body = put_in(fixture("responses/mixed.json"), ["answers", "department", "probabilities", "sales"], 1.07)

      assert_invalid_response(
        Response.from_wire(body, nil, prepared(documented_questions())),
        ["answers", "department", "probabilities", "sales"],
        "too big: must be at most 1"
      )
    end

    test "returns an error, not a crash, for an integer too large for a float" do
      body = put_in(fixture("responses/score.json"), ["answers", "frustration", "score"], 10 ** 400)

      assert_invalid_response(Response.from_wire(body, nil), ["answers", "frustration", "score"], "number is too large")
    end

    test "reports the first malformed answer by wire id, so errors are deterministic" do
      body = %{
        "model" => "jev-latest",
        "answers" => %{
          "zeta" => %{"type" => "noul", "noul" => 3},
          "alpha" => %{"type" => "noul"},
          "mid" => "not an object"
        }
      }

      assert_invalid_response(Response.from_wire(body, nil), ["answers", "alpha", "noul"], "is required")
    end
  end

  # Frozen copies of real API responses. test/fixtures/live/ is rewritten by every live run, so
  # offline tests never read from it.
  describe "recorded API responses" do
    test "decodes the recorded three-question response" do
      questions = %{
        is_urgent: TypeSafe.noul("Urgent?"),
        department: TypeSafe.choice("Team?", billing: nil, technical: nil, sales: nil),
        frustration: TypeSafe.score("Frustration?", ["Calm", "Frustrated", "Very angry"])
      }

      assert {:ok, response} =
               Response.from_wire(fixture("responses/recorded_systemone.json"), "req_live", prepared(questions))

      assert %Response{model: "jev-1.13.0", usage: %Usage{input_tokens: 414, output_tokens: 73}} = response
      assert response.answers.is_urgent == %Answer.Noul{noul: 0.95}
      assert %Answer.Choice{choice: :billing, confidence: 0.79} = response.answers.department
      assert response.answers.department.probabilities == %{billing: 0.86, sales: 0.0, technical: 0.14}
      assert %Answer.Score{score: 1.03, legend: %{0 => "Calm"}} = response.answers.frustration
    end

    test "decodes the recorded structured response" do
      questions = [
        route: TypeSafe.choice(%{task: "Route"}, billing: %{covers: ["refunds"]}, technical: ["bugs"], other: nil),
        severity: TypeSafe.score(["Rate", "severity"], [%{level: "low"}, ["medium"], "high"]),
        refund: TypeSafe.noul(nil, criteria: %{true: %{asks_for: "refund"}, false: nil})
      ]

      assert {:ok, response} =
               Response.from_wire(fixture("responses/recorded_structured.json"), nil, prepared(questions))

      assert response.answers[:route].choice == :billing
      assert response.answers[:route].probabilities == %{billing: 1.0, other: 0.0, technical: 0.0}
      assert response.answers[:severity].legend == %{0 => %{"level" => "low"}, 1 => ["medium"], 2 => "high"}
      assert response.answers[:refund] == %Answer.Noul{noul: 0.88}
    end
  end

  describe "fetch/2 and fetch!/2" do
    setup do
      {:ok, response} = Response.from_wire(fixture("responses/mixed.json"), nil, prepared(documented_questions()))
      %{response: response}
    end

    test "fetch/2 returns the answer or :error", %{response: response} do
      assert Response.fetch(response, :is_urgent) == {:ok, %Answer.Noul{noul: 0.92}}
      assert Response.fetch(response, :missing) == :error
      assert Response.fetch(response, "is_urgent") == :error
    end

    test "fetch!/2 returns the answer", %{response: response} do
      assert %Answer.Score{score: 1.6} = Response.fetch!(response, :frustration)
    end

    test "fetch!/2 raises KeyError naming the id and listing the available ids", %{response: response} do
      error = assert_raise KeyError, fn -> Response.fetch!(response, "is_urgent") end

      assert error.key == "is_urgent"
      assert error.term == response

      assert Exception.message(error) ==
               ~s(no TypeSafe answer for question id "is_urgent"; answers exist for [:department, :frustration, :is_urgent])
    end

    test "fetch!/2 lists no ids for an empty response" do
      assert_raise KeyError, "no TypeSafe answer for question id :a; answers exist for []", fn ->
        Response.fetch!(%Response{}, :a)
      end
    end
  end

  describe "nouls/1, choices/1 and scores/1" do
    test "return the answers of one type, keyed by id" do
      {:ok, response} = Response.from_wire(fixture("responses/mixed.json"), nil, prepared(documented_questions()))

      assert Response.nouls(response) == %{is_urgent: response.answers.is_urgent}
      assert Response.choices(response) == %{department: response.answers.department}
      assert Response.scores(response) == %{frustration: response.answers.frustration}
    end

    test "return an empty map when no answer has that type" do
      response = %Response{answers: %{a: %Answer.Noul{noul: 0.1}}}

      assert {Response.nouls(%Response{}), Response.choices(response), Response.scores(response)} == {%{}, %{}, %{}}
    end
  end

  defp documented_questions do
    [
      department: TypeSafe.choice("Which team should handle this?", billing: nil, technical: nil, sales: nil),
      is_urgent: TypeSafe.noul("Does this convey urgency?"),
      frustration: TypeSafe.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
    ]
  end

  defp prepared(questions) do
    {:ok, prepared} = Question.prepare(questions)
    prepared
  end
end
