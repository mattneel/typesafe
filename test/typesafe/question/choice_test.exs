defmodule TypeSafe.Question.ChoiceTest do
  use ExUnit.Case, async: true

  import TypeSafe.Assertions

  alias TypeSafe.Error
  alias TypeSafe.Question.Choice

  @instructions "Which team should handle this?"
  @options_error "choice criteria must be a map, a keyword list or a list of options"
  @option_key_error "expected an atom or a non-empty string"

  describe "new/3 criteria shapes" do
    test "a keyword list keeps the caller's order" do
      criteria = [technical: "Bugs, outages, integrations", billing: "Payments, invoicing, refunds", sales: nil]

      assert Choice.new(@instructions, criteria) ==
               {:ok, %Choice{instructions: @instructions, criteria: criteria, extra: %{}}}
    end

    test "a list of pairs keeps order and each option's key type" do
      criteria = [{"Beaver Dam Logistics", nil}, {:beaver, "Beaver"}, {"Dam", nil}]

      assert {:ok, %Choice{criteria: ^criteria}} = Choice.new(@instructions, criteria)
    end

    test "a map is sorted by option name" do
      assert {:ok, %Choice{criteria: [billing: "Payments", sales: nil, technical: "Bugs"]}} =
               Choice.new(@instructions, %{technical: "Bugs", sales: nil, billing: "Payments"})
    end

    test "a map with atom and string options is sorted by their string form" do
      assert {:ok, %Choice{criteria: [{"Other", nil}, {:billing, "Payments"}, {"sales", nil}]}} =
               Choice.new(@instructions, %{"sales" => nil, :billing => "Payments", "Other" => nil})
    end

    test "a plain list of options gets nil descriptions in order" do
      assert {:ok, %Choice{criteria: [{:technical, nil}, {"billing", nil}, {:sales, nil}]}} =
               Choice.new(@instructions, [:technical, "billing", :sales])
    end

    test "plain options and pairs can be mixed" do
      assert {:ok, %Choice{criteria: [calm: nil, angry: "Hostile or threatening"]}} =
               Choice.new("Tone?", [:calm, {:angry, "Hostile or threatening"}])
    end

    test "boolean atoms are ordinary options" do
      assert {:ok, %Choice{criteria: [true: nil, false: nil]}} = Choice.new("Is it?", [true, false])
    end

    test "keeps structured descriptions exactly as given" do
      subtree = %{
        "Cycling" => ["Bike Bottles & Cages", "Bike Lights", "Helmets"],
        "Fitness" => ["Yoga Mats", "Resistance Bands"]
      }

      rubric = %{what: "Charges, invoices, refunds", examples: ["I was charged twice"], priority: 1}

      assert {:ok, choice} =
               Choice.new(%{question: "Which department?"}, [{"Sporting Goods", subtree}, billing: rubric])

      assert choice.criteria === [{"Sporting Goods", subtree}, {:billing, rubric}]
      assert choice.instructions === %{question: "Which department?"}
    end

    test "instructions may be nil" do
      assert {:ok, %Choice{instructions: nil}} = Choice.new(nil, [:calm, :angry])
    end
  end

  describe "new/3 with invalid input" do
    test "rejects the empty atom as an option" do
      assert_invalid_request(
        Choice.new("Tone?", [:"", :calm]),
        ["criteria", "0", "0"],
        "expected an atom or a non-empty string"
      )
    end

    test "needs at least one option" do
      assert_invalid_request(Choice.new(@instructions, []), ["criteria"], "choice criteria needs at least one option")
      assert_invalid_request(Choice.new(@instructions, %{}), ["criteria"], "choice criteria needs at least one option")
    end

    test "rejects criteria that is not a map or a list" do
      for criteria <- [nil, "billing", 42, :billing, URI.parse("https://typesafe.ai")] do
        assert_invalid_request(Choice.new(@instructions, criteria), ["criteria"], @options_error)
      end
    end

    test "rejects tuples instead of turning them into lists" do
      assert_invalid_request(Choice.new(@instructions, {:billing, "Payments"}), ["criteria"], @options_error)
      assert_invalid_request(Choice.new(@instructions, {{:billing, nil}, {:sales, nil}}), ["criteria"], @options_error)
    end

    test "rejects improper lists instead of raising" do
      assert_invalid_request(Choice.new(@instructions, [:billing | :sales]), ["criteria"], @options_error)
      assert_invalid_request(Choice.new(@instructions, [{:billing, nil} | {:sales, nil}]), ["criteria"], @options_error)

      assert_invalid_request(
        Choice.new(@instructions, billing: ["Payments" | "Refunds"]),
        ["criteria", "0", "1"],
        "expected JSON data, got an improper list"
      )
    end

    test "rejects options that are not atoms or non-empty strings" do
      for criteria <- [[""], [{"", "Empty"}], [{nil, "Nil"}], [{1, "One"}], %{1 => "One"}, [{["billing"], nil}]] do
        assert_invalid_request(Choice.new(@instructions, criteria), ["criteria", "0", "0"], @option_key_error)
      end
    end

    test "points at the offending entry by position" do
      assert_invalid_request(
        Choice.new(@instructions, [:billing, {"", nil}]),
        ["criteria", "1", "0"],
        @option_key_error
      )
    end

    test "rejects list entries that are neither options nor pairs" do
      for entry <- [nil, 1, ["billing", "Payments"], %{billing: "Payments"}] do
        assert_invalid_request(Choice.new(@instructions, [entry]), ["criteria", "0"], "invalid type: expected tuple")
      end

      assert_invalid_request(
        Choice.new(@instructions, [{:billing, "Payments", :extra}]),
        ["criteria", "0"],
        "invalid tuple: expected length 2, got 3"
      )
    end

    test "rejects options that are equal after string conversion" do
      for criteria <- [
            [:billing, "billing"],
            [billing: "Payments", billing: "Refunds"],
            %{:billing => nil, "billing" => nil}
          ] do
        assert_invalid_request(Choice.new(@instructions, criteria), ["criteria"], ~s(duplicate choice option "billing"))
      end
    end

    test "rejects invalid descriptions with the path to the value" do
      assert_invalid_request(
        Choice.new(@instructions, billing: "Payments", sales: {:pricing}),
        ["criteria", "1", "1"],
        "expected a string, map, list or nil"
      )

      assert_invalid_request(
        Choice.new(@instructions, billing: %{"examples" => ["I was charged twice", self()]}),
        ["criteria", "0", "1", "examples", "1"],
        ~r/^expected JSON data, got #PID/
      )
    end

    test "positions in map criteria follow the sorted option order" do
      assert_invalid_request(
        Choice.new(@instructions, %{technical: 42, billing: "Payments"}),
        ["criteria", "1", "1"],
        "expected a string, map, list or nil"
      )
    end

    test "rejects invalid instructions" do
      assert_invalid_request(Choice.new(42, [:billing]), ["instructions"], "expected a string, map, list or nil")

      assert_invalid_request(
        Choice.new(["ok", {:bad}], [:billing]),
        ["instructions", "1"],
        "expected JSON data, got {:bad}"
      )
    end
  end

  describe "to_wire/1" do
    test "returns string keys, string options and null descriptions" do
      choice = TypeSafe.choice(@instructions, [{:billing, "Payments, invoicing, refunds"}, {"technical", nil}])

      assert Choice.to_wire(choice) == %{
               "type" => "choice",
               "instructions" => @instructions,
               "criteria" => %{"billing" => "Payments, invoicing, refunds", "technical" => nil}
             }
    end

    test "sends structured descriptions as JSON structure, not as strings" do
      rubric = %{what: "Order status, delivery", not_for: "Charges", examples: ["Where is my package?"]}

      assert %{"criteria" => %{"orders" => sent}} = Choice.to_wire(TypeSafe.choice(@instructions, orders: rubric))
      assert sent === rubric
    end

    test "adds extra fields next to the question fields" do
      choice = TypeSafe.choice(@instructions, [:billing], extra: %{"multi_label" => false})

      assert Choice.to_wire(choice) == %{
               "type" => "choice",
               "instructions" => @instructions,
               "criteria" => %{"billing" => nil},
               "multi_label" => false
             }
    end
  end

  describe "TypeSafe.choice/3" do
    test "builds a Choice with the :extra option" do
      assert TypeSafe.choice("Tone?", [:calm, :angry], extra: %{hint: "short"}) ==
               %Choice{instructions: "Tone?", criteria: [calm: nil, angry: nil], extra: %{hint: "short"}}
    end

    test "raises TypeSafe.Error for an invalid question" do
      error = assert_raise Error, fn -> TypeSafe.choice("Tone?", [:calm, "calm"]) end

      assert %Error{type: :invalid_request, path: ["criteria"], message: ~s(duplicate choice option "calm")} = error
    end
  end
end
