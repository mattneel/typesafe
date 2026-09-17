defmodule TypeSafe.LiveTest do
  # Smoke tests against the real API. Excluded by default; run with:
  #
  #     TYPESAFE_API_KEY=... mix test --only live
  #
  # Each run records the raw responses under test/fixtures/live/ so wire changes show up as a
  # diff. CI runs this on a schedule with a repository secret and never on forks.
  use ExUnit.Case, async: false

  alias TypeSafe.Answer
  alias TypeSafe.Response

  @moduletag :live
  @moduletag timeout: 120_000

  @live_dir Path.expand("fixtures/live", __DIR__)

  setup_all do
    case System.get_env("TYPESAFE_API_KEY") do
      key when is_binary(key) and key != "" ->
        {:ok, client: TypeSafe.new(api_key: key, req_options: [])}

      _ ->
        raise "live tests need TYPESAFE_API_KEY"
    end
  end

  test "asks all three question types in one request", %{client: client} do
    questions = %{
      is_urgent:
        TypeSafe.noul("Does this convey urgency?",
          criteria: %{true: "Explicitly time-sensitive", false: "No urgency expressed"}
        ),
      department:
        TypeSafe.choice("Which team should handle this?",
          billing: "Payments, invoicing, refunds",
          technical: "Bugs, outages, integrations",
          sales: nil
        ),
      frustration: TypeSafe.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
    }

    assert {:ok, %Response{} = response} =
             TypeSafe.ask(client, "Help! My payouts have been failing for 3 days.", questions)

    record("systemone.json", response.raw)

    assert is_binary(response.model)
    assert "req_" <> _ = response.request_id
    assert is_integer(response.usage.input_tokens)

    assert %Answer.Noul{noul: noul} = response.answers.is_urgent
    assert noul >= 0 and noul <= 1

    assert %Answer.Choice{choice: choice, probabilities: probabilities, confidence: confidence} =
             response.answers.department

    assert choice in [:billing, :technical, :sales]
    assert probabilities |> Map.keys() |> Enum.sort() == [:billing, :sales, :technical]
    assert_in_delta probabilities |> Map.values() |> Enum.sum(), 1.0, 0.05
    assert confidence >= 0 and confidence <= 1

    assert %Answer.Score{score: score, legend: legend, probabilities: levels} = response.answers.frustration
    assert score >= 0 and score <= 2
    assert legend == %{0 => "Calm", 1 => "Frustrated", 2 => "Very angry"}
    assert levels |> Map.keys() |> Enum.sort() == [0, 1, 2]
  end

  test "passes structured state, instructions and criteria through as JSON", %{client: client} do
    state = %{messages: [%{role: "user", text: "Please refund my duplicate charge"}]}

    questions = [
      route:
        TypeSafe.choice(%{task: "Route the ticket", notes: ["Prefer billing for charges"]},
          billing: %{covers: ["refunds", "charges"]},
          technical: ["bugs", "outages"],
          other: nil
        ),
      severity: TypeSafe.score(["Rate", "severity"], [%{level: "low"}, ["medium"], "high"]),
      refund: TypeSafe.noul(nil, criteria: %{true: %{asks_for: "refund"}, false: nil})
    ]

    assert {:ok, response} = TypeSafe.ask(client, state, questions)
    record("structured.json", response.raw)

    assert response.answers[:route].choice in [:billing, :technical, :other]
    assert response.answers[:severity].legend == %{0 => %{"level" => "low"}, 1 => ["medium"], 2 => "high"}
    assert response.answers[:refund].noul >= 0
  end

  test "string question ids and options round-trip as strings", %{client: client} do
    questions = %{"tone" => TypeSafe.choice("What is the tone?", ["calm", "angry"])}

    assert {:ok, %Response{answers: %{"tone" => %Answer.Choice{choice: choice}}}} =
             TypeSafe.ask(client, "This is the third time I am asking. Fix it now.", questions)

    assert choice in ["calm", "angry"]
  end

  test "lists models", %{client: client} do
    assert {:ok, [_ | _] = models} = TypeSafe.list_models(client)
    record("models.json", %{"models" => Enum.map(models, &Map.from_struct/1)})
    assert Enum.any?(models, &(&1.name == "jev-latest"))
  end

  test "maps a bad API key to an authentication error", %{client: client} do
    bad = TypeSafe.new(api_key: "ts_invalid_key", base_url: client.base_url, retry: false)

    assert {:error, %TypeSafe.Error{type: :authentication, status: 401, request_id: "req_" <> _}} =
             TypeSafe.ask(bad, "hello", %{a: TypeSafe.noul("Is this a greeting?")})
  end

  test "maps an unknown model to a bad request error", %{client: client} do
    assert {:error, %TypeSafe.Error{type: :bad_request, status: 400, message: message}} =
             TypeSafe.ask(client, "hello", %{a: TypeSafe.noul("Is this a greeting?")}, model: "no-such-model")

    assert message =~ "no-such-model"
  end

  defp record(name, body) do
    File.mkdir_p!(@live_dir)
    File.write!(Path.join(@live_dir, name), TypeSafe.JSON.pretty(body))
  end
end
