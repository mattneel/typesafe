defmodule TypeSafe.Question.ScoreTest do
  use ExUnit.Case, async: true

  import TypeSafe.Assertions

  alias TypeSafe.Error
  alias TypeSafe.Question.Score

  @instructions "How frustrated is the customer?"
  @levels ["Calm", "Frustrated", "Very angry"]
  @list_error "score criteria must be a list of levels"
  @level_error "expected a string, map or list"

  describe "new/3 with valid input" do
    test "accepts an ordered list of levels" do
      assert Score.new(@instructions, @levels) ==
               {:ok, %Score{instructions: @instructions, criteria: @levels, extra: %{}}}
    end

    test "accepts exactly two levels" do
      assert {:ok, %Score{criteria: ["Can wait", "Today"]}} = Score.new("Urgency?", ["Can wait", "Today"])
    end

    test "keeps structured levels exactly as given" do
      levels = [
        %{summary: "One change, clearly stated", signals: ["A single fix or feature"]},
        ["One main change", "plus a small related tweak"],
        "Several independent changes bundled together",
        %{"summary" => "Unrelated", "weight" => 1.5, "blocking" => true}
      ]

      assert {:ok, score} = Score.new(%{question: "How focused is this PR?", note: nil}, levels)
      assert score.criteria === levels
      assert score.instructions === %{question: "How focused is this PR?", note: nil}
    end

    test "instructions may be nil" do
      assert {:ok, %Score{instructions: nil}} = Score.new(nil, @levels)
    end
  end

  describe "new/3 with invalid input" do
    test "needs at least two levels" do
      assert_invalid_request(Score.new(@instructions, []), ["criteria"], "score criteria needs at least two levels")

      assert_invalid_request(
        Score.new(@instructions, ["Only"]),
        ["criteria"],
        "score criteria needs at least two levels"
      )
    end

    test "rejects criteria that is not a list" do
      for criteria <- [nil, "Calm, Frustrated", 3, :calm, %{0 => "Calm", 1 => "Frustrated"}] do
        assert_invalid_request(Score.new(@instructions, criteria), ["criteria"], @list_error)
      end
    end

    test "rejects a tuple of levels instead of turning it into a list" do
      assert_invalid_request(Score.new(@instructions, {"Calm", "Frustrated", "Very angry"}), ["criteria"], @list_error)
    end

    test "rejects improper lists instead of raising" do
      assert_invalid_request(Score.new(@instructions, ["Calm", "Frustrated" | "Very angry"]), ["criteria"], @list_error)

      assert_invalid_request(
        Score.new(@instructions, ["Calm", ["Frustrated" | "Very angry"]]),
        ["criteria", "1"],
        "expected JSON data, got an improper list"
      )
    end

    test "rejects nil levels, which the API refuses" do
      assert_invalid_request(
        Score.new(@instructions, ["Calm", nil]),
        ["criteria", "1"],
        "expected a string, map or list (levels cannot be nil)"
      )
    end

    test "rejects scalar and tuple levels" do
      for level <- [2, 0.5, true, :angry, {"Very", "angry"}] do
        assert_invalid_request(Score.new(@instructions, ["Calm", level]), ["criteria", "1"], @level_error)
      end
    end

    test "rejects non-JSON values nested in a level with the path to the value" do
      assert_invalid_request(
        Score.new(@instructions, ["Calm", %{"signals" => [{"raised", "voice"}]}]),
        ["criteria", "1", "signals", "0"],
        ~s(expected JSON data, got {"raised", "voice"})
      )
    end

    test "reports every invalid level in details" do
      assert {:error, %Error{details: details}} = Score.new(@instructions, ["Calm", nil, 3])

      assert details |> Enum.map(& &1.path) |> Enum.sort() == [["criteria", "1"], ["criteria", "2"]]
    end

    test "rejects invalid instructions" do
      assert_invalid_request(Score.new({:rate}, @levels), ["instructions"], "expected a string, map, list or nil")
    end
  end

  describe "to_wire/1" do
    test "returns string keys with levels in order" do
      assert Score.to_wire(TypeSafe.score(@instructions, @levels)) == %{
               "type" => "score",
               "instructions" => @instructions,
               "criteria" => @levels
             }
    end

    test "sends structured levels as JSON structure, not as strings" do
      levels = [%{level: "low"}, ["medium"], "high"]

      assert %{"criteria" => sent} = Score.to_wire(TypeSafe.score(["Rate", "severity"], levels))
      assert sent === levels
    end

    test "adds extra fields next to the question fields" do
      score = TypeSafe.score(@instructions, @levels, extra: %{"scale" => %{"min" => 0}})

      assert %{"criteria" => @levels, "scale" => %{"min" => 0}} = Score.to_wire(score)
    end
  end

  describe "TypeSafe.score/3" do
    test "builds a Score with the :extra option" do
      assert TypeSafe.score("Urgency?", ["Low", "High"], extra: %{hint: 1}) ==
               %Score{instructions: "Urgency?", criteria: ["Low", "High"], extra: %{hint: 1}}
    end

    test "raises TypeSafe.Error for an invalid question" do
      error = assert_raise Error, fn -> TypeSafe.score("Urgency?", ["Only one"]) end

      assert %Error{type: :invalid_request, path: ["criteria"], message: "score criteria needs at least two levels"} =
               error
    end
  end
end
