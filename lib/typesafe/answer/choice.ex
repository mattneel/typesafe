defmodule TypeSafe.Answer.Choice do
  @moduledoc """
  The answer to a `TypeSafe.Question.Choice`.

    * `choice` - the option with the highest probability.
    * `probabilities` - every option mapped to its probability; the values sum to about 1.
    * `confidence` - how certain the model is, from 0 to 1, derived from the distribution.

  Options come back with the key type you used when building the question: atoms stay atoms
  and strings stay strings.

      iex> answer = %TypeSafe.Answer.Choice{
      ...>   choice: :technical,
      ...>   probabilities: %{billing: 0.08, technical: 0.85, sales: 0.07},
      ...>   confidence: 0.82
      ...> }
      iex> TypeSafe.Answer.Choice.ranked(answer)
      [technical: 0.85, billing: 0.08, sales: 0.07]
      iex> TypeSafe.Answer.Choice.margin(answer)
      0.77

  See [Choice](https://docs.typesafe.ai/primitives/choice.md) and
  [Confidence](https://docs.typesafe.ai/confidence.md) in the TypeSafe docs.
  """

  alias TypeSafe.Question.Choice
  alias TypeSafe.Schema

  @fields %{
    choice: Zoi.string(typespec: quote(do: TypeSafe.Question.Choice.option())),
    probabilities:
      Zoi.map(Zoi.string(), Schema.probability(),
        typespec: quote(do: %{optional(TypeSafe.Question.Choice.option()) => float()})
      ),
    confidence: Schema.probability()
  }

  @schema Zoi.struct(__MODULE__, @fields, coerce: true)

  defstruct [:choice, :confidence, probabilities: %{}]

  @type t :: unquote(Zoi.type_spec(@schema))

  @doc """
  Lists `{option, probability}` pairs from most to least likely.

  Ties keep a stable order by option name.
  """
  @spec ranked(t()) :: [{Choice.option(), float()}]
  def ranked(%__MODULE__{probabilities: probabilities}) do
    Enum.sort_by(probabilities, fn {option, probability} -> {-probability, to_string(option)} end)
  end

  @doc """
  Returns the top probability minus the second, rounded to 10 decimal places.

  A small margin means the model saw two options as nearly equally likely. With a single option
  the margin is that option's probability.

      iex> TypeSafe.Answer.Choice.margin(%TypeSafe.Answer.Choice{choice: "a", probabilities: %{"a" => 0.55, "b" => 0.45}, confidence: 0.1})
      0.1
  """
  @spec margin(t()) :: float()
  def margin(%__MODULE__{} = answer) do
    case ranked(answer) do
      [{_, first}, {_, second} | _] -> Float.round(first - second, 10)
      [{_, only}] -> only
      [] -> 0.0
    end
  end

  @doc "The Zoi schema that decodes a Choice answer from the API's JSON."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc false
  @spec wire_schema() :: Zoi.schema()
  def wire_schema do
    probability = Zoi.number() |> Zoi.gte(0) |> Zoi.lte(1)

    Zoi.map(%{
      type: Zoi.literal("choice"),
      choice: Zoi.string(),
      probabilities: Zoi.map(Zoi.string(), probability, []),
      confidence: probability
    })
  end

  @doc false
  @spec wire_json_schema() :: map()
  def wire_json_schema do
    probability = Zoi.number() |> Zoi.gte(0) |> Zoi.lte(1) |> Schema.encode_json()
    put_in(Schema.encode_json(wire_schema()), [:properties, :probabilities], Schema.object_of(probability))
  end

  @doc """
  Decodes a Choice answer from the API's JSON (a map with string keys).

  `options` maps each option's wire string back to the caller's key; options missing from it
  stay strings.

      iex> wire = %{"type" => "choice", "choice" => "calm", "probabilities" => %{"calm" => 0.9, "angry" => 0.1}, "confidence" => 0.8}
      iex> {:ok, answer} = TypeSafe.Answer.Choice.from_wire(wire, %{"calm" => :calm, "angry" => :angry})
      iex> answer.choice
      :calm
  """
  @spec from_wire(map(), %{String.t() => Choice.option()}) ::
          {:ok, t()} | {:error, [Zoi.Error.t()]}
  def from_wire(map, options \\ %{}) do
    with {:ok, answer} <- Zoi.parse(@schema, map) do
      lookup = fn option -> Map.get(options, option, option) end

      {:ok,
       %{
         answer
         | choice: lookup.(answer.choice),
           probabilities: Map.new(answer.probabilities, fn {option, probability} -> {lookup.(option), probability} end)
       }}
    end
  end
end
