defmodule TypeSafe.Question.Noul do
  @moduledoc """
  A yes/no question. The answer is the probability, from 0 to 1, that the answer is yes.

  Build one with `TypeSafe.noul/2` or `new/3`:

      iex> TypeSafe.noul("Does this convey urgency?")
      %TypeSafe.Question.Noul{instructions: "Does this convey urgency?", criteria: nil, extra: %{}}

      iex> TypeSafe.noul("Does this convey urgency?",
      ...>   criteria: %{true: "Explicitly time-sensitive", false: "No urgency expressed"}
      ...> ).criteria
      %{false: "No urgency expressed", true: "Explicitly time-sensitive"}

  `instructions` and each criteria entry accept JSON structure: a string, a map, a list or
  `nil`. Criteria keys may be `true`/`false` atoms or `"true"`/`"false"` strings; either may be
  left out. A Noul needs instructions or at least one criteria entry, which the API also requires.

  `extra` holds additional wire fields for API features newer than this SDK; it is empty unless
  you set it.

  See [Noul](https://docs.typesafe.ai/primitives/noul.md) in the TypeSafe docs.
  """

  alias TypeSafe.Schema

  @fields %{
    instructions: Schema.entry(),
    criteria:
      %{true: Zoi.optional(Schema.entry()), false: Zoi.optional(Schema.entry())}
      |> Zoi.map(unrecognized_keys: :error, error: "noul criteria must be a map with true and false keys")
      # `error: nil` stops the nullable union inheriting the map's message, which would hide
      # the path of an invalid entry nested inside the criteria.
      |> Zoi.nullable(error: nil, typespec: quote(do: TypeSafe.Question.Noul.criteria() | nil)),
    extra: Schema.extra()
  }

  @schema __MODULE__
          |> Zoi.struct(@fields)
          |> Zoi.refine({__MODULE__, :validate_content, []})

  defstruct [:instructions, criteria: nil, extra: %{}]

  @typedoc "Descriptions of what a yes (`true`) and a no (`false`) mean."
  @type criteria :: %{optional(true) => TypeSafe.Question.entry(), optional(false) => TypeSafe.Question.entry()}

  @type t :: unquote(Zoi.type_spec(@schema))

  @doc """
  Builds and validates a Noul question.

  ## Options

    * `:extra` - a map of additional wire fields to send with the question.

  Returns `{:error, %TypeSafe.Error{type: :invalid_request}}` when a value is not JSON, a
  criteria key is not `true` or `false`, or both instructions and criteria are empty.

      iex> {:ok, noul} = TypeSafe.Question.Noul.new("Is this spam?", %{"true" => "Unsolicited advertising"})
      iex> noul.criteria
      %{true: "Unsolicited advertising"}

      iex> {:error, error} = TypeSafe.Question.Noul.new(nil)
      iex> error.message
      "noul question needs instructions or criteria"
  """
  @spec new(TypeSafe.Question.entry(), map() | keyword() | nil, keyword()) :: {:ok, t()} | {:error, TypeSafe.Error.t()}
  def new(instructions, criteria \\ nil, opts \\ []) do
    case repeated_criteria_key(criteria) do
      nil ->
        Schema.build_question(
          @schema,
          %__MODULE__{instructions: instructions, criteria: normalize_criteria(criteria)},
          opts
        )

      key ->
        {:error,
         TypeSafe.Error.invalid_request("noul criteria sets #{key} more than once", path: ["criteria", to_string(key)])}
    end
  end

  @doc "The Zoi schema that validates a Noul question struct."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc false
  @spec wire_schema() :: Zoi.schema()
  def wire_schema do
    criteria = Zoi.map(%{true: Zoi.optional(Schema.entry_json()), false: Zoi.optional(Schema.entry_json())})
    Schema.question_wire_schema("noul", Zoi.nullish(criteria))
  end

  @doc """
  Returns the question as the API's JSON structure, with string keys.

      iex> TypeSafe.Question.Noul.to_wire(TypeSafe.noul("Is this spam?", criteria: [true: "Advertising"]))
      %{"type" => "noul", "instructions" => "Is this spam?", "criteria" => %{"true" => "Advertising"}}
  """
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = question), do: question |> wire() |> TypeSafe.JSON.to_plain()

  @doc false
  @spec wire(t()) :: TypeSafe.JSON.Object.t()
  def wire(%__MODULE__{instructions: instructions, criteria: criteria, extra: extra}) do
    criteria_pair =
      case criteria do
        nil ->
          []

        %{} = criteria ->
          pairs = for key <- [true, false], Map.has_key?(criteria, key), do: {Atom.to_string(key), criteria[key]}
          [{"criteria", TypeSafe.JSON.object(pairs)}]
      end

    TypeSafe.JSON.object(
      [{"type", "noul"}, {"instructions", instructions}] ++ criteria_pair ++ Schema.extra_pairs(extra || %{})
    )
  end

  @doc false
  @spec validate_content(t(), keyword()) :: :ok | {:error, String.t()}
  def validate_content(%__MODULE__{instructions: instructions, criteria: criteria}, _opts) do
    has_instructions? = instructions not in [nil, ""]
    has_criteria? = is_map(criteria) and Enum.any?(criteria, fn {_key, value} -> value not in [nil, ""] end)

    if has_instructions? or has_criteria?, do: :ok, else: {:error, "noul question needs instructions or criteria"}
  end

  # `%{"true" => a, true: b}` names the same outcome twice; reject it instead of keeping one.
  defp repeated_criteria_key(criteria) when (is_map(criteria) and not is_struct(criteria)) or is_list(criteria) do
    if (is_map(criteria) or Schema.proper_list?(criteria)) and Enum.all?(criteria, &match?({_, _}, &1)) do
      criteria
      |> Enum.map(fn {key, _value} -> normalize_key(key) end)
      |> Enum.frequencies()
      |> Enum.find(fn {key, count} -> count > 1 and is_boolean(key) end)
      |> case do
        {key, _count} -> key
        nil -> nil
      end
    end
  end

  defp repeated_criteria_key(_criteria), do: nil

  defp normalize_criteria(nil), do: nil

  defp normalize_criteria(criteria) when is_list(criteria) or (is_map(criteria) and not is_struct(criteria)) do
    if (is_map(criteria) or Schema.proper_list?(criteria)) and Enum.all?(criteria, &match?({_, _}, &1)),
      do: Map.new(criteria, fn {key, value} -> {normalize_key(key), value} end),
      else: criteria
  end

  defp normalize_criteria(criteria), do: criteria

  defp normalize_key("true"), do: true
  defp normalize_key("false"), do: false
  defp normalize_key(key) when is_atom(key) or is_binary(key) or is_number(key), do: key
  # Any other key is rejected, and Zoi renders an unrecognized key with `to_string/1`, which
  # raises for maps, tuples and the like, so it is named by its inspected form instead.
  defp normalize_key(key), do: inspect(key)
end
