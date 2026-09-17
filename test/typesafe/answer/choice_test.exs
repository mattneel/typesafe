defmodule TypeSafe.Answer.ChoiceTest do
  use ExUnit.Case, async: true

  import TypeSafe.TestHelpers

  alias TypeSafe.Answer.Choice

  @documented %{
    "type" => "choice",
    "choice" => "technical",
    "probabilities" => %{"billing" => 0.08, "technical" => 0.85, "sales" => 0.07},
    "confidence" => 0.82
  }

  describe "from_wire/2" do
    test "decodes the documented answer" do
      assert fixture("responses/choice.json")["answers"]["department"] == @documented

      assert Choice.from_wire(@documented) ==
               {:ok,
                %Choice{
                  choice: "technical",
                  probabilities: %{"billing" => 0.08, "technical" => 0.85, "sales" => 0.07},
                  confidence: 0.82
                }}
    end

    test "maps options back to atoms when the question used atoms" do
      lookup = %{"billing" => :billing, "technical" => :technical, "sales" => :sales}

      assert {:ok, %Choice{choice: :technical, probabilities: %{billing: 0.08, technical: 0.85, sales: 0.07}}} =
               Choice.from_wire(@documented, lookup)
    end

    test "keeps each option's own key type when the question mixed atoms and strings" do
      lookup = %{"billing" => :billing, "technical" => "technical", "sales" => :sales}

      assert {:ok, %Choice{choice: "technical", probabilities: probabilities}} = Choice.from_wire(@documented, lookup)
      assert probabilities == %{:billing => 0.08, "technical" => 0.85, :sales => 0.07}
    end

    test "keeps options missing from the lookup as strings" do
      raw = %{@documented | "choice" => "other", "probabilities" => %{"billing" => 0.1, "other" => 0.9}}

      assert {:ok, %Choice{choice: "other", probabilities: %{:billing => 0.1, "other" => 0.9}}} =
               Choice.from_wire(raw, %{"billing" => :billing})
    end

    test "returns integer probabilities and confidence as floats" do
      raw = fixture("responses/integer_probabilities.json")["answers"]["tone"]

      assert {:ok, answer} = Choice.from_wire(raw, %{"calm" => :calm, "angry" => :angry})
      assert {answer.choice, answer.probabilities, answer.confidence} === {:calm, %{calm: 1.0, angry: 0.0}, 1.0}
    end

    test "ignores fields it does not know" do
      assert Choice.from_wire(Map.put(@documented, "entropy", 0.51)) == Choice.from_wire(@documented)
    end

    test "decodes an answer with no probabilities" do
      assert {:ok, %Choice{probabilities: probabilities}} = Choice.from_wire(%{@documented | "probabilities" => %{}})
      assert probabilities == %{}
    end

    test "rejects invalid fields with their paths" do
      cases = [
        {%{@documented | "confidence" => 1.2}, :less_than_or_equal_to, [:confidence]},
        {%{@documented | "confidence" => "high"}, :invalid_type, [:confidence]},
        {%{@documented | "choice" => 1}, :invalid_type, [:choice]},
        {%{@documented | "probabilities" => [0.08, 0.85]}, :invalid_type, [:probabilities]},
        {put_in(@documented, ["probabilities", "billing"], -0.1), :greater_than_or_equal_to,
         [:probabilities, "billing"]},
        {put_in(@documented, ["probabilities", "sales"], nil), :invalid_type, [:probabilities, "sales"]}
      ]

      for {raw, code, path} <- cases do
        assert {:error, [%Zoi.Error{code: ^code, path: ^path}]} = Choice.from_wire(raw)
      end
    end

    test "requires choice, probabilities and confidence" do
      assert {:error, errors} = Choice.from_wire(%{"type" => "choice"})

      assert errors |> Enum.map(&{&1.code, &1.path}) |> Enum.sort() == [
               {:required, [:choice]},
               {:required, [:confidence]},
               {:required, [:probabilities]}
             ]
    end
  end

  describe "ranked/1" do
    test "lists options from most to least likely" do
      answer = %Choice{
        choice: :technical,
        probabilities: %{billing: 0.08, technical: 0.85, sales: 0.07},
        confidence: 0.82
      }

      assert Choice.ranked(answer) == [technical: 0.85, billing: 0.08, sales: 0.07]
    end

    test "orders ties by option name, across atom and string options" do
      answer = %Choice{probabilities: %{:sales => 0.3, "billing" => 0.3, :account => 0.3, "other" => 0.1}}

      assert Choice.ranked(answer) == [{:account, 0.3}, {"billing", 0.3}, {:sales, 0.3}, {"other", 0.1}]
    end

    test "handles a single option and no options" do
      assert Choice.ranked(%Choice{probabilities: %{only: 1.0}}) == [only: 1.0]
      assert Choice.ranked(%Choice{probabilities: %{}}) == []
    end
  end

  describe "margin/1" do
    test "returns the top probability minus the second, without float noise" do
      answer = %Choice{probabilities: %{billing: 0.08, technical: 0.85, sales: 0.07}}

      assert Choice.margin(answer) === 0.77
    end

    test "uses probability order, not key order" do
      assert Choice.margin(%Choice{probabilities: %{a: 0.1, b: 0.2, c: 0.7}}) === 0.5
    end

    test "is zero for a tie at the top" do
      assert Choice.margin(%Choice{probabilities: %{a: 0.45, b: 0.45, c: 0.1}}) === 0.0
    end

    test "is the only probability for a single option, and 0.0 without options" do
      assert Choice.margin(%Choice{probabilities: %{only: 0.6}}) === 0.6
      assert Choice.margin(%Choice{probabilities: %{}}) === 0.0
    end
  end
end
