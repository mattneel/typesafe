defmodule TypeSafe.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import TypeSafe.WireHelpers

  alias TypeSafe.Answer
  alias TypeSafe.Error
  alias TypeSafe.Question
  alias TypeSafe.Question.Choice
  alias TypeSafe.Question.Noul
  alias TypeSafe.Question.Score
  alias TypeSafe.Response

  @model "jev-latest"

  describe "questions" do
    property "a Noul is valid exactly when it has instructions or a non-empty criteria entry" do
      check all instructions <- entry(), criteria <- noul_criteria() do
        case Noul.new(instructions, criteria) do
          {:ok, noul} ->
            assert noul_content?(instructions, criteria)
            assert Question.validate(noul) == {:ok, noul}

          {:error, error} ->
            refute noul_content?(instructions, criteria)

            assert %Error{type: :invalid_request, path: [], message: "noul question needs instructions or criteria"} =
                     error
        end
      end
    end

    property "a Choice keeps list order, sorts map options, and restores every option's key" do
      check all instructions <- entry(), {shape, criteria} <- choice_criteria() do
        assert {:ok, choice} = Choice.new(instructions, criteria)

        expected =
          case shape do
            :options -> Enum.map(criteria, &{&1, nil})
            :pairs -> criteria
            :map -> Enum.sort_by(criteria, fn {option, _description} -> to_string(option) end)
          end

        assert choice.criteria == expected
        assert Choice.option_lookup(choice) == Map.new(expected, fn {option, _} -> {to_string(option), option} end)
      end
    end

    property "a Score accepts any list of at least two JSON levels" do
      check all instructions <- entry(), levels <- list_of(level(), max_length: 5) do
        case Score.new(instructions, levels) do
          {:ok, score} ->
            assert [_, _ | _] = levels
            assert score.criteria === levels

          {:error, error} ->
            refute match?([_, _ | _], levels)
            assert %Error{type: :invalid_request, path: ["criteria"]} = error
        end
      end
    end

    property "a request body decodes to each question's to_wire/1 output, in the promised order" do
      check all state <- state(), questions <- questions() do
        assert {:ok, body, prepared} = Question.build_request(state, @model, questions)

        pairs = if is_map(questions), do: Enum.sort_by(questions, &to_string(elem(&1, 0))), else: questions
        wire_ids = Enum.map(pairs, &to_string(elem(&1, 0)))

        assert JSON.decode!(IO.iodata_to_binary(body)) == %{
                 "state" => state,
                 "model" => @model,
                 "questions" => Map.new(pairs, fn {id, question} -> {to_string(id), Question.to_wire(question)} end)
               }

        ordered = decode_ordered(body)
        assert keys(ordered) == ["state", "model", "questions"]
        assert ordered |> get("questions") |> keys() == wire_ids

        for {id, %Choice{criteria: criteria}} <- pairs do
          options = ordered |> get("questions") |> get(to_string(id)) |> get("criteria") |> keys()
          assert options == Enum.map(criteria, &to_string(elem(&1, 0)))
        end

        assert prepared.ids == Map.new(pairs, fn {id, _question} -> {to_string(id), id} end)
      end
    end

    property "tuples anywhere in a question are rejected, never turned into lists" do
      check all levels <- list_of(level(), min_length: 2, max_length: 4), index <- integer(0..(length(levels) - 1)) do
        assert {:error, %Error{type: :invalid_request, path: ["criteria"]}} =
                 Score.new("Rate", List.to_tuple(levels))

        nested = List.update_at(levels, index, &%{"value" => {&1}})

        assert {:error, %Error{type: :invalid_request, path: ["criteria", segment | _]}} = Score.new("Rate", nested)
        assert segment == Integer.to_string(index)
      end
    end

    property "arbitrary constructor arguments return a question or an :invalid_request error" do
      check all(
              instructions <- messy_term(),
              criteria <- messy_term(),
              extra <- messy_term(),
              opts <- one_of([constant(:extra), messy_term()])
            ) do
        for result <- [
              Noul.new(instructions, criteria, extra: extra),
              Choice.new(instructions, criteria, extra: extra),
              Score.new(instructions, criteria, extra: extra),
              Noul.new(instructions, criteria, opts)
            ] do
          assert_question_result(result)
        end
      end
    end

    property "arbitrary request input returns an encoded body or an :invalid_request error" do
      check all(
              state <- one_of([state(), messy_term()]),
              questions <- one_of([questions(), messy_term(), list_of(tuple({term(), term()}))])
            ) do
        case Question.build_request(state, @model, questions) do
          {:ok, body, _prepared} -> assert {:ok, %{}} = TypeSafe.JSON.decode(body)
          {:error, error} -> assert_error_shape(error, :invalid_request)
        end
      end
    end
  end

  describe "answers" do
    property "answer wire maps decode and re-encode to equal maps, ignoring unknown fields" do
      check all {lookup, wire} <- answer_wire(), extra <- extra_fields() do
        assert {:ok, answer} = Answer.from_wire("q", Map.merge(extra, wire), lookup)

        assert Enum.all?(numbers(answer), &is_float/1)
        assert answer_to_wire(answer) == float_fields(wire)
      end
    end

    property "a response decodes every answer under the caller's id" do
      check all(
              entries <- uniq_list_of(tuple({key(), answer_wire()}), uniq_fun: &to_string(elem(&1, 0)), max_length: 5),
              usage <-
                optional_map(%{"input_tokens" => non_negative_integer(), "output_tokens" => non_negative_integer()})
            ) do
        body = %{
          "model" => @model,
          "answers" => Map.new(entries, fn {id, {_lookup, wire}} -> {to_string(id), wire} end),
          "usage" => usage
        }

        prepared = %{
          ids: Map.new(entries, fn {id, _answer} -> {to_string(id), id} end),
          options: Map.new(entries, fn {id, {lookup, _wire}} -> {to_string(id), lookup} end)
        }

        assert {:ok, %Response{} = response} = Response.from_wire(body, "req_1", prepared)
        assert response.raw == body

        assert {response.usage.input_tokens, response.usage.output_tokens} ==
                 {usage["input_tokens"], usage["output_tokens"]}

        assert Map.new(response.answers, fn {id, answer} -> {id, answer_to_wire(answer)} end) ==
                 Map.new(entries, fn {id, {_lookup, wire}} -> {id, float_fields(wire)} end)
      end
    end

    property "an out-of-range probability is an :invalid_response error at its path" do
      check all(
              {lookup, wire} <- answer_wire(),
              bad <- one_of([float(min: 1.000001, max: 1.0e6), float(min: -1.0e6, max: -1.0e-6)])
            ) do
        {field_path, invalid} = break_probability(wire, bad)

        assert {:error, %Error{type: :invalid_response, path: path}} = Answer.from_wire("q", invalid, lookup)
        assert path == ["answers", "q" | field_path]
      end
    end

    @tag capture_log: true
    property "malformed JSON answers and bodies return answers, :skip or an :invalid_response error" do
      check all raw <- wire_like_answer(), body <- one_of([json_value(), wire_like_body()]) do
        case Answer.from_wire("q", raw) do
          {:ok, answer} -> assert answer.__struct__ in [Answer.Noul, Answer.Choice, Answer.Score]
          :skip -> assert is_binary(raw["type"]) and raw["type"] not in ["noul", "choice", "score"]
          {:error, error} -> assert_error_shape(error, :invalid_response)
        end

        case Response.from_wire(body, nil) do
          {:ok, response} -> assert %Response{raw: ^body} = response
          {:error, error} -> assert_error_shape(error, :invalid_response)
        end
      end
    end
  end

  ## Generators

  defp text, do: string(:printable, max_length: 12)

  defp key do
    [string(:printable, min_length: 1, max_length: 12), atom(:alphanumeric)]
    |> one_of()
    |> filter(&(not is_nil(&1)))
  end

  # `term/0` plus improper lists, alone and nested, which pass `is_list/1` but are not JSON.
  defp messy_term do
    improper =
      map({list_of(term(), min_length: 1, max_length: 3), filter(term(), &(not is_list(&1)))}, fn {items, tail} ->
        items ++ tail
      end)

    one_of([
      term(),
      improper,
      map_of(text(), improper, min_length: 1, max_length: 2),
      list_of(improper, min_length: 1, max_length: 2)
    ])
  end

  # Integers JSON allows but a float cannot hold.
  defp huge_integer,
    do:
      map({integer(309..400), boolean()}, fn {exponent, negative} ->
        if negative, do: -(10 ** exponent), else: 10 ** exponent
      end)

  defp json_scalar, do: one_of([text(), integer(), float(), boolean(), constant(nil)])

  defp json_value do
    json_scalar()
    |> tree(fn child -> one_of([list_of(child, max_length: 3), map_of(text(), child, max_length: 3)]) end)
    |> scale(&min(&1, 12))
  end

  defp json_object, do: map_of(text(), json_value(), max_length: 3)

  defp json_array, do: list_of(json_value(), max_length: 3)

  defp entry, do: one_of([text(), json_object(), json_array(), constant(nil)])

  defp level, do: one_of([text(), json_object(), json_array()])

  defp state, do: one_of([text(), json_object(), json_array()])

  defp noul_criteria do
    criteria = optional_map(%{true: entry(), false: entry()})
    one_of([constant(nil), criteria, map(criteria, &Map.new(&1, fn {key, value} -> {Atom.to_string(key), value} end))])
  end

  defp choice_criteria do
    [key()]
    |> one_of()
    |> uniq_list_of(uniq_fun: &to_string/1, min_length: 1, max_length: 5)
    |> bind(fn options ->
      descriptions = list_of(entry(), length: length(options))

      one_of([
        constant({:options, options}),
        map(descriptions, &{:pairs, Enum.zip(options, &1)}),
        map(descriptions, &{:map, Map.new(Enum.zip(options, &1))})
      ])
    end)
  end

  defp question do
    noul =
      {entry(), noul_criteria()}
      |> filter(fn {instructions, criteria} -> noul_content?(instructions, criteria) end)
      |> map(fn {instructions, criteria} -> TypeSafe.noul(instructions, criteria: criteria) end)

    choice =
      map({entry(), choice_criteria()}, fn {instructions, {_shape, criteria}} ->
        TypeSafe.choice(instructions, criteria)
      end)

    score =
      map({entry(), list_of(level(), min_length: 2, max_length: 4)}, fn {instructions, levels} ->
        TypeSafe.score(instructions, levels)
      end)

    one_of([noul, choice, score])
  end

  defp questions do
    {key(), question()}
    |> tuple()
    |> uniq_list_of(uniq_fun: &to_string(elem(&1, 0)), min_length: 1, max_length: 4)
    |> bind(&one_of([constant(&1), constant(Map.new(&1))]))
  end

  defp probability, do: one_of([float(min: 0.0, max: 1.0), integer(0..1)])

  # Returns `{option_lookup, wire_answer}`, the lookup mapping wire option strings to caller keys.
  defp answer_wire do
    noul = map(probability(), &{%{}, %{"type" => "noul", "noul" => &1}})

    choice =
      bind(uniq_list_of(key(), uniq_fun: &to_string/1, min_length: 1, max_length: 5), fn options ->
        map({fixed_list(Enum.map(options, fn _ -> probability() end)), member_of(options), probability()}, fn
          {probabilities, choice, confidence} ->
            wire = %{
              "type" => "choice",
              "choice" => to_string(choice),
              "probabilities" => options |> Enum.map(&to_string/1) |> Enum.zip(probabilities) |> Map.new(),
              "confidence" => confidence
            }

            {Map.new(options, &{to_string(&1), &1}), wire}
        end)
      end)

    score =
      bind(list_of(level(), min_length: 2, max_length: 5), fn levels ->
        scores = one_of([float(min: -1.0, max: 10.0), integer(-1..10)])

        map({fixed_list(Enum.map(levels, fn _ -> probability() end)), scores, probability()}, fn
          {probabilities, score, confidence} ->
            wire = %{
              "type" => "score",
              "score" => score,
              "legend" => indexed(levels),
              "probabilities" => indexed(probabilities),
              "confidence" => confidence
            }

            {%{}, wire}
        end)
      end)

    one_of([noul, choice, score])
  end

  defp extra_fields,
    do: map_of(map(string(:alphanumeric, min_length: 1, max_length: 8), &("x_" <> &1)), json_value(), max_length: 2)

  # Decoding only ever sees JSON, so the malformed input stays JSON-shaped: string keys and
  # JSON values in the wrong places.
  defp wire_like_answer do
    fields = %{
      "type" => one_of([member_of(["noul", "choice", "score"]), json_value()]),
      "noul" => one_of([probability(), huge_integer(), json_value()]),
      "choice" => json_value(),
      "probabilities" => one_of([map_of(text(), probability(), max_length: 3), json_value()]),
      "confidence" => one_of([probability(), huge_integer(), json_value()]),
      "score" => one_of([float(), huge_integer(), json_value()]),
      "legend" => one_of([map_of(member_of(["0", "1", "-1", "x"]), json_value(), max_length: 3), json_value()])
    }

    one_of([optional_map(fields), json_value()])
  end

  defp wire_like_body do
    optional_map(%{
      "model" => json_value(),
      "answers" => one_of([map_of(text(), wire_like_answer(), max_length: 3), json_value()]),
      "usage" => one_of([optional_map(%{"input_tokens" => json_value(), "output_tokens" => integer()}), json_value()])
    })
  end

  ## Helpers

  defp noul_content?(instructions, criteria) do
    instructions not in [nil, ""] or
      (is_map(criteria) and Enum.any?(criteria, fn {_key, value} -> value not in [nil, ""] end))
  end

  defp indexed(values),
    do: values |> Enum.with_index() |> Map.new(fn {value, index} -> {Integer.to_string(index), value} end)

  defp answer_to_wire(%Answer.Noul{noul: noul}), do: %{"type" => "noul", "noul" => noul}

  defp answer_to_wire(%Answer.Choice{} = answer) do
    %{
      "type" => "choice",
      "choice" => to_string(answer.choice),
      "probabilities" =>
        Map.new(answer.probabilities, fn {option, probability} -> {to_string(option), probability} end),
      "confidence" => answer.confidence
    }
  end

  defp answer_to_wire(%Answer.Score{} = answer) do
    %{
      "type" => "score",
      "score" => answer.score,
      "legend" => Map.new(answer.legend, fn {level, value} -> {Integer.to_string(level), value} end),
      "probabilities" =>
        Map.new(answer.probabilities, fn {level, probability} -> {Integer.to_string(level), probability} end),
      "confidence" => answer.confidence
    }
  end

  # The numbers the SDK promises as floats; legend levels are caller data and stay as sent.
  defp numbers(%Answer.Noul{noul: noul}), do: [noul]
  defp numbers(%Answer.Choice{} = answer), do: [answer.confidence | Map.values(answer.probabilities)]
  defp numbers(%Answer.Score{} = answer), do: [answer.score, answer.confidence | Map.values(answer.probabilities)]

  defp float_fields(%{"type" => "noul"} = wire), do: Map.update!(wire, "noul", &(&1 * 1.0))

  defp float_fields(wire) do
    wire
    |> Map.update!("confidence", &(&1 * 1.0))
    |> Map.update!("probabilities", &Map.new(&1, fn {key, probability} -> {key, probability * 1.0} end))
    |> then(&if Map.has_key?(&1, "score"), do: Map.update!(&1, "score", fn score -> score * 1.0 end), else: &1)
  end

  defp break_probability(%{"type" => "noul"} = wire, bad), do: {["noul"], %{wire | "noul" => bad}}

  defp break_probability(%{"probabilities" => probabilities} = wire, bad) do
    key = probabilities |> Map.keys() |> Enum.min()
    {["probabilities", key], put_in(wire, ["probabilities", key], bad)}
  end

  defp assert_question_result({:ok, question}), do: assert(question.__struct__ in [Noul, Choice, Score])
  defp assert_question_result({:error, error}), do: assert_error_shape(error, :invalid_request)

  defp assert_error_shape(error, type) do
    assert %Error{type: ^type, message: message, path: path, details: [_ | _] = details} = error
    assert is_binary(message)
    assert Enum.all?(path, &is_binary/1)
    assert Enum.all?(details, &match?(%Zoi.Error{}, &1))
  end
end
