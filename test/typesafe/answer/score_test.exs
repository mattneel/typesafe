defmodule TypeSafe.Answer.ScoreTest do
  use ExUnit.Case, async: true

  import TypeSafe.TestHelpers

  alias TypeSafe.Answer.Score

  @documented %{
    "type" => "score",
    "score" => 1.6,
    "legend" => %{"0" => "Calm", "1" => "Frustrated", "2" => "Very angry"},
    "probabilities" => %{"0" => 0.05, "1" => 0.3, "2" => 0.65},
    "confidence" => 0.78
  }

  @legend %{0 => "Calm", 1 => "Frustrated", 2 => "Very angry"}

  describe "from_wire/1" do
    test "decodes the documented answer with integer level keys" do
      assert fixture("responses/score.json")["answers"]["frustration"] == @documented

      assert Score.from_wire(@documented) ==
               {:ok,
                %Score{
                  score: 1.6,
                  legend: @legend,
                  probabilities: %{0 => 0.05, 1 => 0.3, 2 => 0.65},
                  confidence: 0.78
                }}
    end

    test "keeps structured levels in the legend as JSON data" do
      raw = fixture("responses/recorded_structured.json")["answers"]["severity"]

      assert {:ok, %Score{legend: legend}} = Score.from_wire(raw)
      assert legend == %{0 => %{"level" => "low"}, 1 => ["medium"], 2 => "high"}
    end

    test "returns integer score, probabilities and confidence as floats" do
      raw = fixture("responses/integer_probabilities.json")["answers"]["urgency"]

      assert {:ok, answer} = Score.from_wire(raw)
      assert {answer.score, answer.probabilities, answer.confidence} === {2.0, %{0 => 0.0, 1 => 0.0, 2 => 1.0}, 1.0}
    end

    test "allows a score above 1, since it is a position along the levels" do
      assert {:ok, %Score{score: 2.0}} = Score.from_wire(%{@documented | "score" => 2})
    end

    test "rejects an integer score too large for a float instead of raising" do
      for score <- [10 ** 400, -(10 ** 400)] do
        assert {:error, [%Zoi.Error{path: [:score], message: "number is too large"}]} =
                 Score.from_wire(%{@documented | "score" => score})
      end

      largest = trunc(1.797_693_134_862_315_7e308)
      assert {:ok, %Score{score: 1.797_693_134_862_315_7e308}} = Score.from_wire(%{@documented | "score" => largest})
    end

    test "decodes empty legend and probabilities" do
      assert {:ok, %Score{legend: legend, probabilities: probabilities}} =
               Score.from_wire(%{@documented | "legend" => %{}, "probabilities" => %{}})

      assert {legend, probabilities} == {%{}, %{}}
    end

    test "ignores fields it does not know" do
      assert Score.from_wire(Map.put(@documented, "variance", 0.34)) == Score.from_wire(@documented)
    end

    test "rejects level keys that are not non-negative integers" do
      for {key, code} <- [{"zero", :invalid_type}, {"1.5", :invalid_type}, {"-1", :greater_than_or_equal_to}] do
        assert {:error, [%Zoi.Error{code: ^code, path: [:legend, ^key]}]} =
                 Score.from_wire(put_in(@documented, ["legend", key], "Calm"))

        assert {:error, [%Zoi.Error{code: ^code, path: [:probabilities, ^key]}]} =
                 Score.from_wire(put_in(@documented, ["probabilities", key], 0.0))
      end
    end

    test "rejects null and scalar legend levels" do
      assert {:error,
              [%Zoi.Error{path: [:legend, "1"], message: "expected a string, map or list (levels cannot be nil)"}]} =
               Score.from_wire(put_in(@documented, ["legend", "1"], nil))

      assert {:error, [%Zoi.Error{path: [:legend, "1"], message: "expected a string, map or list"}]} =
               Score.from_wire(put_in(@documented, ["legend", "1"], 1))
    end

    test "rejects invalid numbers with their paths" do
      cases = [
        {%{@documented | "score" => "1.6"}, :invalid_type, [:score]},
        {%{@documented | "confidence" => 1.5}, :less_than_or_equal_to, [:confidence]},
        {put_in(@documented, ["probabilities", "2"], 1.2), :less_than_or_equal_to, [:probabilities, "2"]},
        {%{@documented | "legend" => ["Calm", "Frustrated"]}, :invalid_type, [:legend]}
      ]

      for {raw, code, path} <- cases do
        assert {:error, [%Zoi.Error{code: ^code, path: ^path}]} = Score.from_wire(raw)
      end
    end

    test "requires every field" do
      assert {:error, errors} = Score.from_wire(%{"type" => "score"})

      assert errors |> Enum.map(& &1.path) |> Enum.sort() == [[:confidence], [:legend], [:probabilities], [:score]]
    end
  end

  describe "expected_level/1" do
    test "rounds the score to the nearest level" do
      for {score, level} <- [{1.6, 2}, {1.4, 1}, {1.5, 2}, {0.49, 0}, {0.0, 0}, {2.0, 2}] do
        assert Score.expected_level(score(score)) == {level, @legend[level]}
      end
    end

    test "clamps to the legend's range" do
      assert Score.expected_level(score(-1.2)) == {0, "Calm"}
      assert Score.expected_level(score(3.7)) == {2, "Very angry"}
      assert Score.expected_level(%Score{score: 0.2, legend: %{1 => "Low", 2 => "High"}}) == {1, "Low"}
    end

    test "returns nil for the entry of a level missing from the legend" do
      assert Score.expected_level(%Score{score: 1.1, legend: %{0 => "Low", 2 => "High"}}) == {1, nil}
    end

    test "returns nil when the legend is empty" do
      assert Score.expected_level(%Score{score: 1.6, legend: %{}}) == nil
    end
  end

  describe "max_level/1" do
    test "returns the most likely level and its legend entry" do
      assert Score.max_level(%Score{legend: @legend, probabilities: %{0 => 0.05, 1 => 0.3, 2 => 0.65}}) ==
               {2, "Very angry"}
    end

    test "gives ties to the lower level" do
      assert Score.max_level(%Score{legend: @legend, probabilities: %{0 => 0.2, 1 => 0.4, 2 => 0.4}}) ==
               {1, "Frustrated"}
    end

    test "can disagree with the rounded score" do
      answer = %Score{score: 1.05, legend: @legend, probabilities: %{0 => 0.45, 1 => 0.05, 2 => 0.5}}

      assert {Score.expected_level(answer), Score.max_level(answer)} == {{1, "Frustrated"}, {2, "Very angry"}}
    end

    test "returns nil without probabilities and a nil entry for a level missing from the legend" do
      assert Score.max_level(%Score{legend: @legend, probabilities: %{}}) == nil
      assert Score.max_level(%Score{legend: %{}, probabilities: %{3 => 1.0}}) == {3, nil}
    end
  end

  describe "ranked/1" do
    test "lists levels from most to least likely, ties to the lower level" do
      answer = %Score{probabilities: %{0 => 0.25, 1 => 0.25, 2 => 0.5, 3 => 0.0}}

      assert Score.ranked(answer) == [{2, 0.5}, {0, 0.25}, {1, 0.25}, {3, 0.0}]
    end

    test "returns an empty list without probabilities" do
      assert Score.ranked(%Score{probabilities: %{}}) == []
    end
  end

  defp score(value), do: %Score{score: value, legend: @legend}
end
