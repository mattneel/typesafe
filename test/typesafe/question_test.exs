defmodule TypeSafe.QuestionTest do
  use ExUnit.Case, async: true

  import TypeSafe.Assertions
  import TypeSafe.TestHelpers
  import TypeSafe.WireHelpers

  alias TypeSafe.JSON.Object
  alias TypeSafe.Question
  alias TypeSafe.Question.Choice
  alias TypeSafe.Question.Noul
  alias TypeSafe.Question.Score

  @support_state "Help! My payouts have been failing for 3 days."

  describe "validate/1" do
    test "returns constructor-built questions unchanged" do
      for question <- [
            TypeSafe.noul("Urgent?", criteria: %{true: "Yes"}),
            TypeSafe.choice("Team?", billing: nil, technical: "Bugs"),
            TypeSafe.score("Urgency?", ["Low", "High"], extra: %{hint: 1})
          ] do
        assert Question.validate(question) == {:ok, question}
      end
    end

    test "accepts hand-built structs and normalises their criteria like the constructors" do
      assert Question.validate(%Noul{instructions: "Urgent?", criteria: %{"false" => "No"}}) ==
               {:ok, %Noul{instructions: "Urgent?", criteria: %{false: "No"}, extra: %{}}}

      assert Question.validate(%Choice{instructions: "Team?", criteria: %{technical: nil, billing: nil}}) ==
               {:ok, %Choice{instructions: "Team?", criteria: [billing: nil, technical: nil], extra: %{}}}

      assert Question.validate(%Score{instructions: "Urgency?", criteria: ["Low", "High"]}) ==
               {:ok, %Score{instructions: "Urgency?", criteria: ["Low", "High"], extra: %{}}}
    end

    test "rejects hand-built structs left at their defaults" do
      assert_invalid_request(Question.validate(%Noul{}), [], "noul question needs instructions or criteria")
      assert_invalid_request(Question.validate(%Choice{}), ["criteria"], "choice criteria needs at least one option")
      assert_invalid_request(Question.validate(%Score{}), ["criteria"], "score criteria needs at least two levels")
    end

    test "rejects a hand-built struct whose extra is not a map" do
      assert_invalid_request(
        Question.validate(%Noul{instructions: "Urgent?", extra: nil}),
        ["extra"],
        "invalid type: expected map"
      )
    end

    test "rejects values that are not questions" do
      for value <- [nil, "Urgent?", %{type: "noul", instructions: "Urgent?"}, URI.parse("https://typesafe.ai")] do
        assert_invalid_request(Question.validate(value), [], ~r/^expected a TypeSafe question \(TypeSafe\.noul\/2/)
      end
    end
  end

  describe "to_wire/1" do
    test "dispatches to each question type" do
      assert %{"type" => "noul"} = Question.to_wire(TypeSafe.noul("Urgent?"))
      assert %{"type" => "choice", "criteria" => %{"a" => nil}} = Question.to_wire(TypeSafe.choice("Pick", [:a]))

      assert %{"type" => "score", "criteria" => ["Low", "High"]} =
               Question.to_wire(TypeSafe.score("Rate", ["Low", "High"]))
    end
  end

  describe "prepare/1" do
    test "rejects the empty atom as a question id" do
      assert {:error, %TypeSafe.Error{type: :invalid_request, path: ["questions", ~s(:"")]}} =
               Question.prepare([{:"", TypeSafe.noul("Urgent?")}])
    end

    test "returns the ordered wire object and lookups that restore the caller's keys" do
      questions = [
        {:department, TypeSafe.choice("Team?", [:technical, {"billing", "Payments"}])},
        {"is_urgent", TypeSafe.noul("Urgent?")},
        {:frustration, TypeSafe.score("Frustration?", ["Calm", "Angry"])}
      ]

      assert {:ok, prepared} = Question.prepare(questions)

      assert %Object{pairs: [{"department", %Object{}}, {"is_urgent", %Object{}}, {"frustration", %Object{}}]} =
               prepared.object

      assert prepared.ids == %{"department" => :department, "is_urgent" => "is_urgent", "frustration" => :frustration}
      assert prepared.options == %{"department" => %{"technical" => :technical, "billing" => "billing"}}
      assert prepared.types == %{"department" => "choice", "is_urgent" => "noul", "frustration" => "score"}
    end

    test "orders map input by the string form of each id" do
      questions = %{"zeta" => TypeSafe.noul("Z?"), alpha: TypeSafe.noul("A?"), Beta: TypeSafe.noul("B?")}

      assert {:ok, %{object: %Object{pairs: pairs}}} = Question.prepare(questions)
      assert Enum.map(pairs, &elem(&1, 0)) == ["Beta", "alpha", "zeta"]
    end

    test "rejects an improper list of questions instead of raising" do
      assert_invalid_request(
        Question.prepare([{:a, TypeSafe.noul("Urgent?")} | :tail]),
        ["questions"],
        ~r/^questions must be a map or keyword list of TypeSafe questions, got: \[{:a, .*\| :tail\]$/
      )
    end

    test "needs at least one question" do
      assert_invalid_request(Question.prepare([]), ["questions"], "at least one question is required")
      assert_invalid_request(Question.prepare(%{}), ["questions"], "at least one question is required")
    end

    test "rejects a questions value that is not a map or list" do
      for questions <- [nil, "is_urgent", {:is_urgent, TypeSafe.noul("Urgent?")}, TypeSafe.noul("Urgent?")] do
        assert_invalid_request(
          Question.prepare(questions),
          ["questions"],
          ~r/^questions must be a map or keyword list of TypeSafe questions, got: /
        )
      end
    end

    test "rejects ids that are not atoms or non-empty strings" do
      question = TypeSafe.noul("Urgent?")

      for {id, segment} <- [{nil, "nil"}, {"", ~s("")}, {1, "1"}, {{:is, :urgent}, "{:is, :urgent}"}] do
        assert_invalid_request(
          Question.prepare([{id, question}]),
          ["questions", segment],
          "question ids must be atoms or non-empty strings, got: #{inspect(id)}"
        )
      end
    end

    test "rejects list entries that are not {id, question} pairs, by position" do
      question = TypeSafe.noul("Urgent?")

      assert_invalid_request(
        Question.prepare([question]),
        ["questions", "0"],
        ~r/^expected an {id, question} pair, got: /
      )

      assert_invalid_request(
        Question.prepare([{:a, question}, {:b, question, :extra}]),
        ["questions", "1"],
        ~r/^expected an {id, question} pair, got: {:b,/
      )
    end

    test "rejects ids that are equal after string conversion" do
      question = TypeSafe.noul("Urgent?")

      for questions <- [
            [a: question, a: question],
            [{:a, question}, {"a", question}],
            %{:a => question, "a" => question}
          ] do
        assert_invalid_request(Question.prepare(questions), ["questions", "a"], ~s(duplicate question id "a"))
      end
    end

    test "rejects values that are not questions, under their id" do
      assert_invalid_request(
        Question.prepare(is_urgent: TypeSafe.noul("Urgent?"), tone: %{type: "choice"}),
        ["questions", "tone"],
        ~r/^expected a TypeSafe question/
      )
    end

    test "prefixes a question's validation paths, including every detail, with its id" do
      invalid = %Choice{instructions: 42, criteria: [billing: {:bad}]}

      assert {:error, %TypeSafe.Error{type: :invalid_request, path: ["questions", "dept" | _]} = error} =
               Question.prepare(dept: invalid)

      assert error.details |> Enum.map(& &1.path) |> Enum.sort() == [
               ["questions", "dept", "criteria", "0", "1"],
               ["questions", "dept", "instructions"]
             ]
    end

    test "reports the first invalid question in the caller's order" do
      assert {:error, %{path: ["questions", "second" | _]}} =
               Question.prepare([{"second", %Score{criteria: []}}, {"first", %Noul{}}])
    end
  end

  describe "ids/1" do
    test "lists ids in wire order without validating" do
      assert Question.ids(b: :not_validated, a: nil) == [:b, :a]
      assert Question.ids(%{"b" => 1, :a => 2}) == [:a, "b"]
      assert Question.ids([{:a, 1}, :not_a_pair]) == [:a]
      assert Question.ids(nil) == []
      assert Question.ids([{:a, 1} | :tail]) == []
    end
  end

  describe "build_request/3" do
    test "encodes state, model and questions in that order" do
      assert {:ok, body, prepared} =
               Question.build_request("Refund please", "jev-preview", tone: TypeSafe.choice("Tone?", [:calm]))

      assert body |> decode_ordered() |> keys() == ["state", "model", "questions"]
      assert JSON.decode!(IO.iodata_to_binary(body))["model"] == "jev-preview"
      assert {:ok, prepared} == Question.prepare(tone: TypeSafe.choice("Tone?", [:calm]))
    end

    test "accepts string, map and list state and sends it as JSON structure" do
      for state <- [
            "",
            @support_state,
            %{"ticket" => %{"messages" => [%{"from" => "customer"}]}},
            [%{"role" => "user"}, "hi"]
          ] do
        assert {:ok, body, _prepared} = Question.build_request(state, "jev-latest", a: TypeSafe.noul("Urgent?"))
        assert JSON.decode!(IO.iodata_to_binary(body))["state"] == state
      end
    end

    test "encodes structs in state that implement JSON.Encoder" do
      assert {:ok, body, _prepared} =
               Question.build_request(%{opened_on: ~D[2026-09-16]}, "jev-latest", a: TypeSafe.noul("Urgent?"))

      assert JSON.decode!(IO.iodata_to_binary(body))["state"] == %{"opened_on" => "2026-09-16"}
    end

    test "rejects state that is not a string, map or list" do
      for state <- [nil, 42, 1.5, true, :ticket, {"ticket"}] do
        assert_invalid_request(
          Question.build_request(state, "jev-latest", a: TypeSafe.noul("Urgent?")),
          ["state"],
          "state must be a string, map or list, got: #{inspect(state)}"
        )
      end
    end

    test "rejects non-JSON values nested in state with the path to the value" do
      questions = [a: TypeSafe.noul("Urgent?")]

      assert_invalid_request(
        Question.build_request(%{"messages" => [%{"at" => {2026, 9, 16}}]}, "jev-latest", questions),
        ["state", "messages", "0", "at"],
        "expected JSON data, got {2026, 9, 16}"
      )

      assert_invalid_request(
        Question.build_request(<<0xFF>>, "jev-latest", questions),
        ["state"],
        "expected valid UTF-8 text"
      )

      assert_invalid_request(
        Question.build_request([URI.parse("https://typesafe.ai")], "jev-latest", questions),
        ["state", "0"],
        "expected JSON data, got a URI struct that does not implement JSON.Encoder"
      )
    end

    test "rejects improper lists in state and questions instead of raising" do
      question = TypeSafe.noul("Urgent?")

      assert_invalid_request(
        Question.build_request(%{"messages" => ["hi" | "there"]}, "jev-latest", a: question),
        ["state", "messages"],
        "expected JSON data, got an improper list"
      )

      assert_invalid_request(Question.build_request([1 | 2], "jev-latest", a: question), ["state"], ~r/improper list/)

      assert_invalid_request(
        Question.build_request("text", "jev-latest", [{:a, question} | :tail]),
        ["questions"],
        ~r/^questions must be/
      )
    end

    test "validates state before questions" do
      assert_invalid_request(Question.build_request(nil, "jev-latest", []), ["state"], ~r/^state must be/)
    end

    test "returns question errors" do
      assert_invalid_request(
        Question.build_request("text", "jev-latest", []),
        ["questions"],
        "at least one question is required"
      )
    end

    test "rejects a hand-built question holding a tuple before anything is encoded" do
      assert_invalid_request(
        Question.build_request("text", "jev-latest", levels: %Score{instructions: "Rate", criteria: {"Low", "High"}}),
        ["questions", "levels", "criteria"],
        "score criteria must be a list of levels"
      )
    end
  end

  describe "wire encoding matches the documented requests" do
    for name <- ~w(noul noul_criteria choice score mixed structured_instructions structured_choice_rubric
                   structured_taxonomy structured_score_levels structured_noul_criteria) do
      test "requests/#{name}.json" do
        name = unquote(name)
        {state, questions} = documented_request(name)

        assert {:ok, body, _prepared} = Question.build_request(state, "jev-latest", questions)
        assert JSON.decode!(IO.iodata_to_binary(body)) == fixture("requests/#{name}.json")

        assert request_order(decode_ordered(body)) ==
                 request_order(decode_ordered(fixture_raw("requests/#{name}.json")))
      end
    end

    test "each documented question's to_wire/1 equals its entry in the fixture" do
      {_state, questions} = documented_request("structured_instructions")
      documented = fixture("requests/structured_instructions.json")["questions"]

      for {id, question} <- questions do
        assert JSON.decode!(JSON.encode!(Question.to_wire(question))) == documented[Atom.to_string(id)]
      end
    end

    test "map input sends the same questions, sorted by id" do
      {state, questions} = documented_request("mixed")

      assert {:ok, body, _prepared} = Question.build_request(state, "jev-latest", Map.new(questions))
      assert JSON.decode!(IO.iodata_to_binary(body)) == fixture("requests/mixed.json")
      assert body |> decode_ordered() |> get("questions") |> keys() == ["department", "frustration", "is_urgent"]
    end
  end

  describe "wire key order" do
    test "keeps question and option order from keyword lists, byte for byte" do
      questions = [
        urgent: TypeSafe.noul("Urgent?", criteria: [false: "No", true: "Yes"], extra: %{zeta: 1, alpha: "a"}),
        team: TypeSafe.choice("Team?", technical: "Bugs", billing: nil, account: %{what: "Login"}),
        level: TypeSafe.score("Level?", ["Low", %{name: "High"}])
      ]

      assert {:ok, body, _prepared} = Question.build_request("Refund please", "jev-latest", questions)

      assert IO.iodata_to_binary(body) ==
               ~s({"state":"Refund please","model":"jev-latest","questions":{) <>
                 ~s("urgent":{"type":"noul","instructions":"Urgent?","criteria":{"true":"Yes","false":"No"},) <>
                 ~s("alpha":"a","zeta":1},) <>
                 ~s("team":{"type":"choice","instructions":"Team?",) <>
                 ~s("criteria":{"technical":"Bugs","billing":null,"account":{"what":"Login"}}},) <>
                 ~s("level":{"type":"score","instructions":"Level?","criteria":["Low",{"name":"High"}]}}})
    end

    test "sorts map questions by id and map options by name, byte for byte" do
      questions = %{
        team: TypeSafe.choice("Team?", %{technical: nil, billing: nil}),
        level: TypeSafe.score("L?", ["a", "b"])
      }

      assert {:ok, body, _prepared} = Question.build_request(["a"], "jev-latest", questions)

      assert IO.iodata_to_binary(body) ==
               ~s({"state":["a"],"model":"jev-latest","questions":{) <>
                 ~s("level":{"type":"score","instructions":"L?","criteria":["a","b"]},) <>
                 ~s("team":{"type":"choice","instructions":"Team?","criteria":{"billing":null,"technical":null}}}})
    end

    test "is the same on every call for the same input" do
      {state, questions} = documented_request("structured_instructions")
      encode = fn -> state |> Question.build_request("jev-latest", Map.new(questions)) |> elem(1) end

      assert IO.iodata_to_binary(encode.()) == IO.iodata_to_binary(encode.())
    end
  end

  describe ":extra option" do
    for type <- [:noul, :choice, :score] do
      test "#{type} stores atom and string keyed fields as given" do
        extra = %{:priority => 1, "labels" => ["billing", %{"weight" => 0.5}]}

        assert {:ok, %{extra: ^extra}} = build(unquote(type), extra: extra)
      end

      test "#{type} appends extra fields after the question fields, sorted by name" do
        {:ok, question} = build(unquote(type), extra: %{"zeta" => nil, beta: [1], alpha: "a"})

        assert {:ok, body, _prepared} = Question.build_request("text", "jev-latest", q: question)
        fields = body |> decode_ordered() |> get("questions") |> get("q") |> keys()

        assert fields == question_fields(unquote(type)) ++ ["alpha", "beta", "zeta"]
      end

      test "#{type} rejects reserved field names" do
        for name <- [:type, "type", :instructions, "instructions", :criteria, "criteria"] do
          assert_invalid_request(
            build(unquote(type), extra: %{name => "x"}),
            ["extra"],
            ~s(extra cannot set the reserved field "#{name}")
          )
        end
      end

      test "#{type} rejects field names that are not atoms or non-empty strings" do
        for name <- [nil, "", 1, {:hint}] do
          assert_invalid_request(
            build(unquote(type), extra: %{name => "x"}),
            ["extra"],
            "extra field names must be atoms or non-empty strings, got: #{inspect(name)}"
          )
        end
      end

      test "#{type} rejects non-JSON values with the path to the value" do
        assert_invalid_request(
          build(unquote(type), extra: %{hint: %{"refs" => [{:ref, 1}]}}),
          ["extra", "hint", "refs", "0"],
          "expected JSON data, got {:ref, 1}"
        )
      end

      test "#{type} rejects an extra that is not a map" do
        for extra <- [[hint: 1], "hint", nil] do
          assert_invalid_request(build(unquote(type), extra: extra), ["extra"], "invalid type: expected map")
        end
      end

      test "#{type} rejects unknown and malformed options" do
        assert_invalid_request(build(unquote(type), hint: 1), [], "unknown question options [:hint]; allowed: [:extra]")

        for opts <- [%{extra: %{}}, [1], :extra, [{:extra, %{}} | :tail]] do
          assert_invalid_request(
            build(unquote(type), opts),
            [],
            "expected question options as a keyword list, got: #{inspect(opts)}"
          )
        end
      end
    end
  end

  defp build(:noul, opts), do: Noul.new("Is this urgent?", nil, opts)
  defp build(:choice, opts), do: Choice.new("Which team?", [:billing], opts)
  defp build(:score, opts), do: Score.new("How urgent?", ["Low", "High"], opts)

  defp question_fields(:noul), do: ["type", "instructions"]
  defp question_fields(_type), do: ["type", "instructions", "criteria"]

  # The Elixir equivalent of each request in test/fixtures/requests, written the way a caller
  # would build it. Keyword lists keep the documented question and option order.
  defp documented_request("noul"), do: {@support_state, [is_urgent: TypeSafe.noul("Does this convey urgency?")]}

  defp documented_request("noul_criteria") do
    criteria = %{true: "Explicitly time-sensitive", false: "No urgency expressed"}
    {@support_state, [is_urgent: TypeSafe.noul("Does this convey urgency?", criteria: criteria)]}
  end

  defp documented_request("choice") do
    {@support_state,
     [
       department:
         TypeSafe.choice("Which team should handle this?",
           billing: "Payments, invoicing, refunds",
           technical: "Bugs, outages, integrations",
           sales: "Pricing, upgrades, new accounts"
         )
     ]}
  end

  defp documented_request("score") do
    {@support_state,
     [frustration: TypeSafe.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])]}
  end

  defp documented_request("mixed") do
    state =
      "Our API integration started returning 500 errors on every request about 20 minutes ago, " <>
        "and we can't process any customer orders until this is fixed."

    {state,
     [
       department:
         TypeSafe.choice("Which team should handle this",
           billing: "Payment or subscription issues",
           technical: "Bugs or integration problems",
           sales: "Pricing or account questions"
         ),
       is_urgent: TypeSafe.noul("The message conveys urgency or time-sensitivity"),
       frustration:
         TypeSafe.score("How frustrated the customer appears", [
           "Calm, just stating facts",
           "Frustrated but civil",
           "Very angry, strong language"
         ])
     ]}
  end

  defp documented_request("structured_instructions") do
    state = %{source_text: "Invoice #4471 issued March 3, 2026 to Beaver Dam Logistics for $12,840.00, net 30."}

    field = fn name, type, extra -> Map.merge(%{name: name, type: type}, Map.new(extra)) end

    {state,
     [
       invoice_number_is_correct:
         TypeSafe.noul(%{
           field: field.("invoice_number", "string", description: "The identifier printed on the invoice."),
           extracted_value: "4471",
           question: "Does `extracted_value` match the `field` as it appears in `source_text`?"
         }),
       customer_name:
         TypeSafe.choice(
           %{
             field: field.("customer_name", "string", description: "The organization the invoice was issued to."),
             question: "Which option is the value of `field` in `source_text`?"
           },
           ["Beaver Logistics", "Dam Logistics", "Beaver Dam Logistics", "Beaver", "Dam"]
         ),
       amount_due:
         TypeSafe.score(
           %{
             field: field.("amount_due", "number", unit: "USD", description: "The total the invoice asks to be paid."),
             question: "How large is the `field` value in `source_text`?"
           },
           ["Under $1,000", "$1,000 to $10,000", "$10,000 to $100,000", "$100,000 to $1,000,000", "Over $1,000,000"]
         ),
       payment_terms:
         TypeSafe.score(
           %{
             field:
               field.("payment_terms", "integer",
                 unit: "days",
                 description: ~s(Days allowed for payment, from terms such as "net 30".)
               ),
             question: "How many days does the `field` in `source_text` allow for payment?"
           },
           ["Due on receipt", "Net 10", "Net 30", "Net 60", "Net 90"]
         )
     ]}
  end

  defp documented_request("structured_choice_rubric") do
    state =
      "I ordered the standing desk two weeks ago and tracking still says label created. Was I even charged?"

    rubric = fn what, not_for, examples -> %{what: what, not_for: not_for, examples: examples} end

    {state,
     [
       department:
         TypeSafe.choice(
           %{
             question: "Which team should handle this message?",
             focus: "Classify the customer's primary request, not every topic mentioned."
           },
           billing:
             rubric.("Charges, invoices, refunds, or subscriptions", "Order tracking or account access", [
               "I was charged twice",
               "Where is my refund?"
             ]),
           orders:
             rubric.("Order status, delivery, cancellation, or returns", "Charges or account access", [
               "Where is my package?",
               "Cancel my order"
             ]),
           account:
             rubric.("Login, password, profile, or security", "Charges or delivery", [
               "I can't log in",
               "Change my email"
             ])
         )
     ]}
  end

  defp documented_request("structured_taxonomy") do
    criteria = [
      {"Sporting Goods",
       %{
         "Cycling" => ["Bike Bottles & Cages", "Bike Lights", "Helmets"],
         "Fitness" => ["Yoga Mats", "Resistance Bands"],
         "Outdoor" => ["Tents", "Sleeping Bags", "Hydration Packs"]
       }},
      {"Home & Kitchen",
       %{"Drinkware" => ["Water Bottles", "Travel Mugs", "Tumblers"], "Cookware" => ["Pots & Pans", "Bakeware"]}},
      {"Baby & Toddler", ["Sippy Cups", "Bottle Warmers", "Bibs"]}
    ]

    {"32oz plastic bottle with a flip straw lid. Fits most bike cages.",
     [department: TypeSafe.choice("Which top-level department does this product belong to?", criteria)]}
  end

  defp documented_request("structured_score_levels") do
    state =
      "Fixed the null check in the payment handler. Also refactored the retry loop while I was in there, " <>
        "and bumped the SDK version since the old one had that timeout bug."

    levels = [
      %{
        summary: "One change, clearly stated",
        signals: ["A single fix or feature", ~s(Nothing described as "also" or "while I was in there")]
      },
      %{
        summary: "One main change plus a small related tweak",
        signals: ["A primary change and one minor adjacent edit", "The tweak supports the main change"]
      },
      %{
        summary: "Several independent changes bundled together",
        signals: ["Two or more unrelated fixes or features", "Changes that could each be their own PR"]
      }
    ]

    instructions = %{
      question: "How focused is this pull request description on a single change?",
      note: "Judge the number of independent changes, not the size of any one change."
    }

    {state, [pr_scope: TypeSafe.score(instructions, levels)]}
  end

  defp documented_request("structured_noul_criteria") do
    state = %{
      sender: %{display_name: "Beaver Dam Builders Ltd.", email: "donotreply@payroll.example"},
      message:
        "Your Q3 bonus is ready. Reply with your login password so we can verify your identity and release the funds."
    }

    instructions = %{
      question: "Does the `message` ask the recipient to disclose a sensitive credential?",
      inspect: "message",
      focus: "Look for a request to send the credential itself, not a request to change or reset it."
    }

    criteria = %{
      true: %{
        what:
          "Asks the recipient to reply with, type, or send a password, PIN, one-time code, " <>
            "or other security sensitive answer",
        examples: ["Reply with your password", "Send us the 6-digit code you just received"]
      },
      false: %{
        what: "No sensitive credential is requested",
        examples: ["Reset your password from the settings page", "Your statement is ready"]
      }
    }

    {state, [requests_credentials: TypeSafe.noul(instructions, criteria: criteria)]}
  end
end
