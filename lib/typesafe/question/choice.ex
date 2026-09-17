defmodule TypeSafe.Question.Choice do
  @moduledoc """
  A question that picks one option from a set you define. The answer carries the top option,
  a probability for every option, and a confidence.

  Build one with `TypeSafe.choice/3` or `new/3`:

      iex> TypeSafe.choice("Which team should handle this?", billing: "Payments, invoicing, refunds", technical: nil)
      %TypeSafe.Question.Choice{
        instructions: "Which team should handle this?",
        criteria: [billing: "Payments, invoicing, refunds", technical: nil],
        extra: %{}
      }

  ## Criteria

  Criteria map each option to a description, or to `nil` when the option name says enough.
  They can be given as:

    * a keyword list or a list of `{option, description}` pairs, which keeps your order,
    * a map, whose options are sent sorted by name so requests are deterministic,
    * a plain list of options, such as `[:billing, :technical, :sales]`, each with a `nil`
      description.

  Option order is part of what the model reads, and reordering options can move probabilities
  by a few points, so use a keyword list when order matters to you.

  Options are atoms or non-empty strings; they go over the wire as strings and come back on
  the answer as whatever you used, so `answer.choice` is `:technical` when you passed atoms.
  Descriptions accept JSON structure: a string, a map, a list or `nil`.

  See [Choice](https://docs.typesafe.ai/primitives/choice.md) in the TypeSafe docs.
  """

  alias TypeSafe.Schema

  @fields %{
    instructions: Schema.entry(),
    criteria:
      {Schema.key(), Schema.entry()}
      |> Zoi.tuple()
      |> Zoi.list(typespec: quote(do: [{TypeSafe.Question.Choice.option(), TypeSafe.Question.entry()}]))
      |> Zoi.min(1, error: "choice criteria needs at least one option")
      |> Zoi.refine({__MODULE__, :validate_unique, []})
      |> Schema.list("choice criteria must be a map, a keyword list or a list of options"),
    extra: Schema.extra()
  }

  @schema Zoi.struct(__MODULE__, @fields)

  defstruct [:instructions, criteria: [], extra: %{}]

  @typedoc "A Choice option: an atom or a non-empty string."
  @type option :: atom() | String.t()

  @type t :: unquote(Zoi.type_spec(@schema))

  @doc """
  Builds and validates a Choice question.

  ## Options

    * `:extra` - a map of additional wire fields to send with the question.

  Returns `{:error, %TypeSafe.Error{type: :invalid_request}}` when there are no options, an
  option is not an atom or non-empty string, two options have the same string form (such as
  `:billing` and `"billing"`), or a value is not JSON.

      iex> {:ok, choice} = TypeSafe.Question.Choice.new("Tone?", [:calm, :angry])
      iex> choice.criteria
      [calm: nil, angry: nil]

      iex> {:error, error} = TypeSafe.Question.Choice.new("Tone?", [])
      iex> error.message
      "choice criteria needs at least one option"
  """
  @spec new(TypeSafe.Question.entry(), map() | list(), keyword()) :: {:ok, t()} | {:error, TypeSafe.Error.t()}
  def new(instructions, criteria, opts \\ []) do
    Schema.build_question(
      @schema,
      %__MODULE__{instructions: instructions, criteria: normalize_criteria(criteria)},
      opts
    )
  end

  @doc "The Zoi schema that validates a Choice question struct."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc false
  @spec wire_schema() :: Zoi.schema()
  def wire_schema do
    Schema.question_wire_schema("choice", Zoi.map(Zoi.min(Zoi.string(), 1), Schema.entry_json(), []))
  end

  @doc false
  @spec wire_json_schema() :: map()
  def wire_json_schema do
    criteria = Schema.object_of(Schema.encode_json(Schema.entry_json()), min: 1, key: %{type: :string, minLength: 1})
    put_in(Schema.encode_json(wire_schema()), [:properties, :criteria], criteria)
  end

  @doc """
  Returns the question as the API's JSON structure, with string keys.

      iex> TypeSafe.Question.Choice.to_wire(TypeSafe.choice("Tone?", calm: nil, angry: "Hostile"))
      %{"type" => "choice", "instructions" => "Tone?", "criteria" => %{"calm" => nil, "angry" => "Hostile"}}
  """
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = question), do: question |> wire() |> TypeSafe.JSON.to_plain()

  @doc false
  @spec wire(t()) :: TypeSafe.JSON.Object.t()
  def wire(%__MODULE__{instructions: instructions, criteria: criteria, extra: extra}) do
    options =
      criteria
      |> Enum.map(fn {option, description} -> {Schema.key_to_string(option), description} end)
      |> TypeSafe.JSON.object()

    TypeSafe.JSON.object(
      [{"type", "choice"}, {"instructions", instructions}, {"criteria", options}] ++ Schema.extra_pairs(extra || %{})
    )
  end

  @doc false
  # Maps each option's wire string back to the caller's key, for decoding answers.
  @spec option_lookup(t()) :: %{String.t() => option()}
  def option_lookup(%__MODULE__{criteria: criteria}) do
    Map.new(criteria, fn {option, _description} -> {Schema.key_to_string(option), option} end)
  end

  @doc false
  @spec validate_unique([{option(), TypeSafe.Question.entry()}], keyword()) :: :ok | {:error, String.t()}
  def validate_unique(pairs, _opts) do
    pairs
    |> Enum.map(fn {option, _} -> Schema.key_to_string(option) end)
    |> Enum.frequencies()
    |> Enum.find(fn {_option, count} -> count > 1 end)
    |> case do
      nil -> :ok
      {option, _count} -> {:error, "duplicate choice option #{inspect(option)}"}
    end
  end

  defp normalize_criteria(%{} = criteria) when not is_struct(criteria), do: Schema.pairs(criteria)

  # An improper list is left as given for the schema to reject.
  defp normalize_criteria(criteria) when is_list(criteria) do
    if Schema.proper_list?(criteria), do: normalize_options(criteria), else: criteria
  end

  defp normalize_criteria(criteria), do: criteria

  defp normalize_options(criteria) do
    Enum.map(criteria, fn
      option when (is_atom(option) and not is_nil(option)) or is_binary(option) -> {option, nil}
      other -> other
    end)
  end
end
