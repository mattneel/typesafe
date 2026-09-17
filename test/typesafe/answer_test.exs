defmodule TypeSafe.AnswerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import TypeSafe.Assertions
  import TypeSafe.TestHelpers

  alias TypeSafe.Answer

  describe "from_wire/3 with documented answers" do
    test "decodes each answer in the mixed response into its struct" do
      answers = fixture("responses/mixed.json")["answers"]
      options = %{"billing" => :billing, "technical" => :technical, "sales" => :sales}

      assert Answer.from_wire("is_urgent", answers["is_urgent"]) == {:ok, %Answer.Noul{noul: 0.92}}

      assert Answer.from_wire("department", answers["department"], options) ==
               {:ok,
                %Answer.Choice{
                  choice: :technical,
                  probabilities: %{billing: 0.08, technical: 0.85, sales: 0.07},
                  confidence: 0.82
                }}

      assert Answer.from_wire("frustration", answers["frustration"]) ==
               {:ok,
                %Answer.Score{
                  score: 1.6,
                  legend: %{0 => "Calm", 1 => "Frustrated", 2 => "Very angry"},
                  probabilities: %{0 => 0.05, 1 => 0.3, 2 => 0.65},
                  confidence: 0.78
                }}
    end

    test "decodes the same answer types with extra fields present" do
      for {id, raw} <- fixture("responses/extra_fields.json")["answers"] do
        assert {:ok, answer} = Answer.from_wire(id, raw)
        assert answer.__struct__ in [Answer.Noul, Answer.Choice, Answer.Score]
      end
    end

    test "Choice options default to strings when no lookup is given" do
      raw = fixture("responses/choice.json")["answers"]["department"]

      assert {:ok, %Answer.Choice{choice: "technical", probabilities: %{"billing" => 0.08}}} =
               Answer.from_wire("department", raw)
    end
  end

  describe "from_wire/3 with unknown answer types" do
    test "skips the answer and logs a warning naming the id and type" do
      raw = fixture("responses/unknown_type.json")["answers"]["logo_region"]

      log = capture_log(fn -> assert Answer.from_wire("logo_region", raw) == :skip end)

      assert log =~ ~s(TypeSafe: ignoring answer "logo_region" with unrecognized type "bounding_box")
    end

    test "skips an unknown type even when its fields look like a known answer" do
      log = capture_log(fn -> assert Answer.from_wire("q", %{"type" => "Noul", "noul" => 0.5}) == :skip end)

      assert log =~ ~s(unrecognized type "Noul")
    end
  end

  describe "from_wire/3 with malformed answers" do
    test "rejects an answer without a string type" do
      for raw <- [%{"noul" => 0.5}, %{"type" => nil, "noul" => 0.5}, %{"type" => :noul}, %{type: "noul"}] do
        assert_invalid_response(
          Answer.from_wire("is_urgent", raw),
          ["answers", "is_urgent", "type"],
          ~s(answer is missing its string "type")
        )
      end
    end

    test "rejects an answer that is not a JSON object" do
      for raw <- [nil, 0.92, "noul", [%{"type" => "noul"}]] do
        assert_invalid_response(
          Answer.from_wire("is_urgent", raw),
          ["answers", "is_urgent", "type"],
          "expected answer to be a JSON object, got: #{inspect(raw)}"
        )
      end
    end

    test "locates an invalid field under the answer's id" do
      assert_invalid_response(
        Answer.from_wire("tone", %{"type" => "choice", "choice" => "calm", "probabilities" => %{}, "confidence" => 1.2}),
        ["answers", "tone", "confidence"],
        "too big: must be at most 1"
      )
    end

    test "prefixes every detail with the answer's id" do
      assert {:error, error} = Answer.from_wire("tone", %{"type" => "choice"})

      assert error.type == :invalid_response
      assert %Zoi.Error{} = hd(error.details)

      assert error.details |> Enum.map(&{&1.code, &1.path}) |> Enum.sort() == [
               {:required, ["answers", "tone", "choice"]},
               {:required, ["answers", "tone", "confidence"]},
               {:required, ["answers", "tone", "probabilities"]}
             ]
    end
  end
end
