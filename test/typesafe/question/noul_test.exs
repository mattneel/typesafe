defmodule TypeSafe.Question.NoulTest do
  use ExUnit.Case, async: true

  import TypeSafe.Assertions

  alias TypeSafe.Error
  alias TypeSafe.Question.Noul

  @instructions "Does this convey urgency?"

  describe "new/3 with valid input" do
    test "accepts instructions alone" do
      assert Noul.new(@instructions) == {:ok, %Noul{instructions: @instructions, criteria: nil, extra: %{}}}
    end

    test "accepts criteria with atom keys" do
      criteria = %{true: "Explicitly time-sensitive", false: "No urgency expressed"}

      assert {:ok, %Noul{criteria: ^criteria}} = Noul.new(@instructions, criteria)
    end

    test "normalises string criteria keys to atoms" do
      assert {:ok, %Noul{criteria: %{true: "Explicitly time-sensitive", false: "No urgency expressed"}}} =
               Noul.new(@instructions, %{"true" => "Explicitly time-sensitive", "false" => "No urgency expressed"})
    end

    test "accepts criteria as a keyword list or a list of string-keyed pairs" do
      assert {:ok, %Noul{criteria: %{true: "Yes", false: "No"}}} = Noul.new(@instructions, false: "No", true: "Yes")
      assert {:ok, %Noul{criteria: %{false: "No"}}} = Noul.new(@instructions, [{"false", "No"}])
    end

    test "either criteria key may be left out" do
      assert {:ok, %Noul{criteria: %{true: "Yes"}}} = Noul.new(@instructions, %{true: "Yes"})
      assert {:ok, %Noul{criteria: %{false: "No"}}} = Noul.new(@instructions, %{false: "No"})
      assert {:ok, %Noul{criteria: %{}}} = Noul.new(@instructions, %{})
    end

    test "criteria alone is enough when instructions are nil or empty" do
      assert {:ok, %Noul{instructions: nil, criteria: %{true: "Asks for a refund"}}} =
               Noul.new(nil, %{true: "Asks for a refund"})

      assert {:ok, %Noul{instructions: ""}} = Noul.new("", %{false: %{asks_for: "nothing"}})
    end

    test "instructions alone are enough when every criteria entry is nil" do
      assert {:ok, %Noul{criteria: %{true: nil, false: nil}}} = Noul.new(@instructions, %{true: nil, false: nil})
    end

    test "keeps structured instructions and criteria exactly as given" do
      instructions = %{
        question: "Does the `message` ask the recipient to disclose a sensitive credential?",
        inspect: "message",
        compare: ["ticket.sender.display_name", "ticket.sender.email"]
      }

      criteria = %{
        true: %{"what" => "Asks for a password", "examples" => ["Reply with your password"]},
        false: ["No credential requested", %{"examples" => []}]
      }

      assert {:ok, noul} = Noul.new(instructions, criteria)
      assert noul.instructions === instructions
      assert noul.criteria === criteria
    end

    test "accepts JSON scalars, atoms and encodable structs nested in structure" do
      instructions = %{
        "count" => 3,
        "ratio" => 0.5,
        "strict" => true,
        "note" => nil,
        "mode" => :exact,
        1 => "numeric keys encode as strings",
        "since" => ~D[2026-09-16]
      }

      assert {:ok, %Noul{instructions: ^instructions}} = Noul.new(instructions)
    end
  end

  describe "new/3 with invalid input" do
    test "rejects criteria that name the same outcome twice" do
      assert_invalid_request(
        Noul.new("Urgent?", %{"true" => "a", true: "b"}),
        ["criteria", "true"],
        "noul criteria sets true more than once"
      )

      assert_invalid_request(
        Noul.new("Urgent?", false: "a", false: "b"),
        ["criteria", "false"],
        "noul criteria sets false more than once"
      )
    end

    test "needs non-empty instructions or at least one non-empty criteria entry" do
      for {instructions, criteria} <- [{nil, nil}, {"", nil}, {nil, %{}}, {nil, %{true: nil}}, {"", %{false: ""}}] do
        assert_invalid_request(Noul.new(instructions, criteria), [], "noul question needs instructions or criteria")
      end
    end

    test "rejects instructions that are not a string, map, list or nil" do
      for instructions <- [42, 1.5, true, :urgent, {"Is this", "urgent?"}] do
        assert_invalid_request(Noul.new(instructions), ["instructions"], "expected a string, map, list or nil")
      end
    end

    test "rejects tuples nested in structure instead of turning them into lists" do
      assert_invalid_request(
        Noul.new(%{"compare" => {"sender.name", "sender.email"}}),
        ["instructions", "compare"],
        ~s(expected JSON data, got {"sender.name", "sender.email"})
      )
    end

    test "rejects non-JSON values nested in structure with the path to the value" do
      assert_invalid_request(
        Noul.new(%{field: %{owner: self()}}),
        ["instructions", "field", "owner"],
        ~r/^expected JSON data, got #PID/
      )

      assert_invalid_request(
        Noul.new(["ok", [make_ref()]]),
        ["instructions", "1", "0"],
        ~r/^expected JSON data, got #Reference/
      )

      assert_invalid_request(
        Noul.new([%{"check" => &is_atom/1}]),
        ["instructions", "0", "check"],
        ~r/^expected JSON data, got &/
      )
    end

    test "rejects invalid UTF-8 text" do
      assert_invalid_request(Noul.new(<<0xFF, 0xFE>>), ["instructions"], "expected valid UTF-8 text")

      assert_invalid_request(
        Noul.new(%{"text" => ["fine", <<0xC3>>]}),
        ["instructions", "text", "1"],
        "expected valid UTF-8 text"
      )
    end

    test "rejects improper lists instead of raising" do
      assert_invalid_request(Noul.new([1 | 2]), ["instructions"], "expected JSON data, got an improper list")

      assert_invalid_request(
        Noul.new(%{"compare" => ["sender.name" | "sender.email"]}),
        ["instructions", "compare"],
        "expected JSON data, got an improper list"
      )

      assert_invalid_request(
        Noul.new(@instructions, %{true: ["Yes" | "Definitely"]}),
        ["criteria", "true"],
        "expected JSON data, got an improper list"
      )

      assert_invalid_request(
        Noul.new(@instructions, [{true, "Yes"} | {false, "No"}]),
        ["criteria"],
        "noul criteria must be a map with true and false keys"
      )
    end

    test "rejects structs that do not implement JSON.Encoder" do
      assert_invalid_request(
        Noul.new(%{"link" => URI.parse("https://typesafe.ai")}),
        ["instructions", "link"],
        "expected JSON data, got a URI struct that does not implement JSON.Encoder"
      )
    end

    test "rejects map keys that cannot be JSON object keys" do
      assert_invalid_request(
        Noul.new(%{"ok" => %{{:not, :a_key} => 1}}),
        ["instructions", "ok"],
        "expected JSON object keys to be strings, atoms or numbers, got {:not, :a_key}"
      )
    end

    test "rejects criteria keys other than true and false" do
      assert {:error, %Error{path: ["criteria"], message: "unrecognized key: maybe", details: [detail]}} =
               Noul.new(@instructions, %{true: "Yes", maybe: "Unsure"})

      assert %Zoi.Error{code: :unrecognized_key, path: ["criteria"]} = detail

      assert_invalid_request(Noul.new(@instructions, %{"yes" => "Urgent"}), ["criteria"], "unrecognized key: yes")
      assert_invalid_request(Noul.new(@instructions, [{1, "Urgent"}]), ["criteria"], "unrecognized key: 1")
    end

    test "names criteria keys that have no string form by their inspected form" do
      assert_invalid_request(
        Noul.new(@instructions, %{{:is, :urgent} => "Yes"}),
        ["criteria"],
        "unrecognized key: {:is, :urgent}"
      )

      assert_invalid_request(Noul.new(@instructions, %{%{} => "Yes"}), ["criteria"], "unrecognized key: %{}")
    end

    test "rejects criteria that is not a map or a list of pairs" do
      for criteria <- ["Urgent", ["Urgent", "Not urgent"], {true, "Urgent"}, URI.parse("https://typesafe.ai"), 1] do
        assert_invalid_request(
          Noul.new(@instructions, criteria),
          ["criteria"],
          "noul criteria must be a map with true and false keys"
        )
      end
    end

    test "rejects invalid criteria entries with the path to the entry" do
      assert_invalid_request(
        Noul.new(@instructions, %{true: {:urgent}}),
        ["criteria", "true"],
        "expected a string, map, list or nil"
      )

      assert_invalid_request(
        Noul.new(@instructions, %{false: %{"examples" => ["Your statement is ready", self()]}}),
        ["criteria", "false", "examples", "1"],
        ~r/^expected JSON data, got #PID/
      )
    end

    test "reports every invalid field in details, each with its full path" do
      assert {:error, %Error{details: details}} = Noul.new(42, %{true: {:urgent}})

      assert details |> Enum.map(& &1.path) |> Enum.sort() == [["criteria", "true"], ["instructions"]]
      assert Enum.all?(details, &match?(%Zoi.Error{code: :custom}, &1))
    end
  end

  describe "to_wire/1" do
    test "returns string keys with criteria true before false" do
      noul = TypeSafe.noul(@instructions, criteria: [false: "No urgency expressed", true: "Explicitly time-sensitive"])

      assert Noul.to_wire(noul) == %{
               "type" => "noul",
               "instructions" => @instructions,
               "criteria" => %{"true" => "Explicitly time-sensitive", "false" => "No urgency expressed"}
             }
    end

    test "omits criteria when there is none and keeps nil instructions as null" do
      assert Noul.to_wire(TypeSafe.noul(@instructions)) == %{"type" => "noul", "instructions" => @instructions}

      assert Noul.to_wire(TypeSafe.noul(nil, criteria: %{false: "No"})) == %{
               "type" => "noul",
               "instructions" => nil,
               "criteria" => %{"false" => "No"}
             }
    end

    test "sends structured values as JSON structure, not as strings" do
      instructions = %{question: "Does the message ask for a credential?", inspect: ["message", "subject"]}
      wire = Noul.to_wire(TypeSafe.noul(instructions, criteria: %{true: %{what: "Asks for a password"}}))

      assert wire["instructions"] === instructions
      assert wire["criteria"] == %{"true" => %{what: "Asks for a password"}}
    end

    test "adds extra fields next to the question fields" do
      noul = TypeSafe.noul(@instructions, extra: %{calibration: "v2"})

      assert Noul.to_wire(noul) == %{"type" => "noul", "instructions" => @instructions, "calibration" => "v2"}
    end
  end

  describe "TypeSafe.noul/2" do
    test "builds a Noul with the :criteria and :extra options" do
      assert TypeSafe.noul(@instructions, criteria: %{"true" => "Yes"}, extra: %{"hint" => 1}) ==
               %Noul{instructions: @instructions, criteria: %{true: "Yes"}, extra: %{"hint" => 1}}
    end

    test "raises TypeSafe.Error for an invalid question" do
      error = assert_raise Error, fn -> TypeSafe.noul(nil) end

      assert %Error{type: :invalid_request, path: [], message: "noul question needs instructions or criteria"} = error
    end

    test "raises for unknown options, naming them" do
      error = assert_raise Error, fn -> TypeSafe.noul(@instructions, criteria: %{true: "Yes"}, threshold: 0.5) end

      assert error.message == "unknown question options [:threshold]; allowed: [:extra]"
    end
  end
end
