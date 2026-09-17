defmodule TypeSafe.Question do
  @moduledoc """
  The three TypeSafe question types, and the types they share.

  | Type | Build with | Answer |
  | --- | --- | --- |
  | `TypeSafe.Question.Noul` | `TypeSafe.noul/2` | `TypeSafe.Answer.Noul`: probability of yes |
  | `TypeSafe.Question.Choice` | `TypeSafe.choice/2` | `TypeSafe.Answer.Choice`: top option, probabilities, confidence |
  | `TypeSafe.Question.Score` | `TypeSafe.score/2` | `TypeSafe.Answer.Score`: weighted score, probabilities, confidence |

  Questions are sent together in one request, keyed by ids you choose. The ids are not sent to
  the model; answers come back under the same ids, with the same key type you used.

  Every `instructions` value, Choice description, Score level and Noul criteria entry accepts
  JSON structure (see [structure](https://docs.typesafe.ai/primitives/advanced.md)). Maps and
  lists are sent as JSON objects and arrays, never stringified.
  """

  alias TypeSafe.JSON.Object
  alias TypeSafe.Question.Choice
  alias TypeSafe.Question.Noul
  alias TypeSafe.Question.Score
  alias TypeSafe.Schema

  @typedoc """
  A JSON value accepted by `instructions`, Choice descriptions and Noul criteria: a string, a
  map, a list or `nil`. Nested values must be JSON too (strings, numbers, booleans, `nil`, atoms,
  lists and maps).
  """
  @type entry :: String.t() | map() | list() | nil

  @typedoc "A Score level: a string, a map or a list. Levels cannot be `nil`."
  @type level :: String.t() | map() | list()

  @typedoc "A question id: an atom or a non-empty string."
  @type id :: atom() | String.t()

  @typedoc "Any TypeSafe question."
  @type t :: Noul.t() | Choice.t() | Score.t()

  @typedoc """
  The questions for one request: a map or a keyword list (or list of `{id, question}` pairs).
  A list keeps its order on the wire; a map is sent sorted by id.
  """
  @type questions :: %{optional(id()) => t()} | [{id(), t()}]

  @doc """
  Validates a question struct, including one built by hand rather than with a constructor.

      iex> TypeSafe.Question.validate(TypeSafe.noul("Is this spam?"))
      {:ok, %TypeSafe.Question.Noul{instructions: "Is this spam?", criteria: nil, extra: %{}}}

      iex> {:error, error} = TypeSafe.Question.validate(%TypeSafe.Question.Score{instructions: "Rate", criteria: ["one"]})
      iex> {error.type, error.path}
      {:invalid_request, ["criteria"]}
  """
  @spec validate(t()) :: {:ok, t()} | {:error, TypeSafe.Error.t()}
  def validate(%Noul{} = question), do: Noul.new(question.instructions, question.criteria, extra: question.extra)
  def validate(%Choice{} = question), do: Choice.new(question.instructions, question.criteria, extra: question.extra)
  def validate(%Score{} = question), do: Score.new(question.instructions, question.criteria, extra: question.extra)

  def validate(other) do
    {:error,
     TypeSafe.Error.invalid_request(
       "expected a TypeSafe question (TypeSafe.noul/2, TypeSafe.choice/2 or TypeSafe.score/2), got: #{inspect(other, limit: 5)}",
       path: []
     )}
  end

  @doc """
  Returns the question as the API's JSON structure, with string keys.

      iex> TypeSafe.Question.to_wire(TypeSafe.score("Urgency?", ["Low", "High"]))
      %{"type" => "score", "instructions" => "Urgency?", "criteria" => ["Low", "High"]}
  """
  @spec to_wire(t()) :: map()
  def to_wire(%Noul{} = question), do: Noul.to_wire(question)
  def to_wire(%Choice{} = question), do: Choice.to_wire(question)
  def to_wire(%Score{} = question), do: Score.to_wire(question)

  @doc false
  @spec wire(t()) :: Object.t()
  def wire(%Noul{} = question), do: Noul.wire(question)
  def wire(%Choice{} = question), do: Choice.wire(question)
  def wire(%Score{} = question), do: Score.wire(question)

  @doc false
  @spec type(t()) :: String.t()
  def type(%Noul{}), do: "noul"
  def type(%Choice{}), do: "choice"
  def type(%Score{}), do: "score"

  @doc false
  @spec wire_schema() :: Zoi.schema()
  def wire_schema do
    Zoi.discriminated_union(:type, [Noul.wire_schema(), Choice.wire_schema(), Score.wire_schema()])
  end

  @doc false
  @spec wire_json_schema() :: map()
  def wire_json_schema do
    Schema.one_of("type", [
      Schema.encode_json(Noul.wire_schema()),
      Choice.wire_json_schema(),
      Schema.encode_json(Score.wire_schema())
    ])
  end

  @doc false
  # Validates state and questions and encodes the System One request body. Returns the encoded
  # body plus the lookups `TypeSafe.Response.from_wire/3` needs to restore the caller's keys.
  @spec build_request(term(), String.t(), term()) :: {:ok, iodata(), map()} | {:error, TypeSafe.Error.t()}
  def build_request(state, model, questions) do
    with {:ok, state} <- validate_state(state),
         {:ok, prepared} <- prepare(questions) do
      body = TypeSafe.JSON.object([{"state", state}, {"model", model}, {"questions", prepared.object}])

      case TypeSafe.JSON.encode(body) do
        {:ok, iodata} ->
          {:ok, iodata, prepared}

        {:error, exception} ->
          {:error, TypeSafe.Error.invalid_request("request is not valid JSON: " <> Exception.message(exception))}
      end
    end
  end

  defp validate_state(state) when is_binary(state) or is_map(state) or is_list(state) do
    case Schema.json_issue(state, []) do
      nil ->
        {:ok, state}

      {message, path} ->
        {:error, TypeSafe.Error.invalid_request(message, path: ["state" | path |> Enum.reverse() |> Schema.path()])}
    end
  end

  defp validate_state(state) do
    {:error,
     TypeSafe.Error.invalid_request("state must be a string, map or list, got: #{inspect(state, limit: 5)}",
       path: ["state"]
     )}
  end

  @doc false
  # Best-effort list of ids for telemetry metadata, before validation.
  @spec ids(term()) :: [term()]
  def ids(%{} = questions) when not is_struct(questions), do: questions |> Schema.pairs() |> Enum.map(&elem(&1, 0))

  def ids(questions) when is_list(questions),
    do: if(Schema.proper_list?(questions), do: for({id, _} <- questions, do: id), else: [])

  def ids(_questions), do: []

  @doc false
  # Validates a questions collection and returns the ordered wire object plus the lookups used
  # to map answer ids and Choice options back to the caller's keys.
  @spec prepare(term()) ::
          {:ok,
           %{
             object: Object.t(),
             ids: %{String.t() => id()},
             options: %{String.t() => %{String.t() => Choice.option()}},
             types: %{String.t() => String.t()}
           }}
          | {:error, TypeSafe.Error.t()}
  def prepare(questions) when (is_map(questions) and not is_struct(questions)) or is_list(questions) do
    pairs = Schema.pairs(questions)

    with :ok <- check_pairs(pairs, questions),
         {:ok, entries} <- prepare_entries(pairs) do
      {:ok,
       %{
         object: TypeSafe.JSON.object(Enum.map(entries, fn {wire_id, _id, question} -> {wire_id, wire(question)} end)),
         ids: Map.new(entries, fn {wire_id, id, _question} -> {wire_id, id} end),
         options: Map.new(for({wire_id, _id, %Choice{} = q} <- entries, do: {wire_id, Choice.option_lookup(q)})),
         types: Map.new(entries, fn {wire_id, _id, question} -> {wire_id, type(question)} end)
       }}
    end
  end

  def prepare(other), do: not_questions(other)

  defp not_questions(other) do
    {:error,
     TypeSafe.Error.invalid_request(
       "questions must be a map or keyword list of TypeSafe questions, got: #{inspect(other, limit: 5)}",
       path: ["questions"]
     )}
  end

  defp check_pairs([], _questions),
    do: {:error, TypeSafe.Error.invalid_request("at least one question is required", path: ["questions"])}

  defp check_pairs(pairs, questions), do: if(Schema.proper_list?(pairs), do: :ok, else: not_questions(questions))

  defp prepare_entries(pairs) do
    pairs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {pair, index}, {:ok, acc, seen} ->
      case prepare_entry(pair, index, seen) do
        {:ok, {wire_id, _id, _question} = entry} -> {:cont, {:ok, [entry | acc], MapSet.put(seen, wire_id)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, entries, _seen} -> {:ok, Enum.reverse(entries)}
      {:error, error} -> {:error, error}
    end
  end

  defp prepare_entry({id, question}, _index, seen)
       when (is_atom(id) and id not in [nil, :""]) or (is_binary(id) and id != "") do
    wire_id = Schema.key_to_string(id)

    if MapSet.member?(seen, wire_id) do
      {:error,
       TypeSafe.Error.invalid_request("duplicate question id #{inspect(wire_id)}", path: ["questions", wire_id])}
    else
      case validate(question) do
        {:ok, question} -> {:ok, {wire_id, id, question}}
        {:error, error} -> {:error, prefix(error, ["questions", wire_id])}
      end
    end
  end

  defp prepare_entry({id, _question}, _index, _seen) do
    {:error,
     TypeSafe.Error.invalid_request("question ids must be atoms or non-empty strings, got: #{inspect(id)}",
       path: ["questions", inspect(id)]
     )}
  end

  defp prepare_entry(other, index, _seen) do
    {:error,
     TypeSafe.Error.invalid_request("expected an {id, question} pair, got: #{inspect(other, limit: 5)}",
       path: ["questions", Integer.to_string(index)]
     )}
  end

  defp prefix(%TypeSafe.Error{} = error, prefix) do
    %{
      error
      | path: prefix ++ (error.path || []),
        details: Enum.map(error.details, fn detail -> %{detail | path: prefix ++ detail.path} end)
    }
  end
end
