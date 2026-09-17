defmodule TypeSafe.Answer.Score do
  @moduledoc """
  The answer to a `TypeSafe.Question.Score`.

    * `score` - the probability-weighted level; it can land between levels, such as `1.6`.
    * `legend` - each level index mapped back to the level you defined.
    * `probabilities` - each level index mapped to its probability; the values sum to about 1.
    * `confidence` - how certain the model is, from 0 to 1, derived from the distribution.

  Level keys arrive from the API as strings (`"0"`, `"1"`, ...) and are decoded to integers, so
  you index with `probabilities[2]`.

      iex> answer = %TypeSafe.Answer.Score{
      ...>   score: 1.6,
      ...>   legend: %{0 => "Calm", 1 => "Frustrated", 2 => "Very angry"},
      ...>   probabilities: %{0 => 0.05, 1 => 0.3, 2 => 0.65},
      ...>   confidence: 0.78
      ...> }
      iex> TypeSafe.Answer.Score.expected_level(answer)
      {2, "Very angry"}
      iex> TypeSafe.Answer.Score.max_level(answer)
      {2, "Very angry"}
      iex> TypeSafe.Answer.Score.ranked(answer)
      [{2, 0.65}, {1, 0.3}, {0, 0.05}]

  See [Score](https://docs.typesafe.ai/primitives/score.md) in the TypeSafe docs.
  """

  alias TypeSafe.Schema

  @fields %{
    score: Schema.number(),
    legend: Zoi.map(Schema.level_index(), Schema.level(), []),
    probabilities: Zoi.map(Schema.level_index(), Schema.probability(), []),
    confidence: Schema.probability()
  }

  @schema Zoi.struct(__MODULE__, @fields, coerce: true)

  defstruct [:score, :confidence, legend: %{}, probabilities: %{}]

  @type t :: unquote(Zoi.type_spec(@schema))

  @doc """
  Rounds the score to the nearest level and returns `{level, legend_entry}`.

  The level is clamped to the legend's range. Returns `nil` when the legend is empty.
  """
  @spec expected_level(t()) :: {non_neg_integer(), TypeSafe.Question.level() | nil} | nil
  def expected_level(%__MODULE__{legend: legend}) when map_size(legend) == 0, do: nil

  def expected_level(%__MODULE__{score: score, legend: legend}) do
    {low, high} = legend |> Map.keys() |> Enum.min_max()
    level = score |> round() |> max(low) |> min(high)
    {level, Map.get(legend, level)}
  end

  @doc """
  Returns the single most likely level as `{level, legend_entry}`, or `nil` when there are no
  probabilities. Ties go to the lower level.
  """
  @spec max_level(t()) :: {non_neg_integer(), TypeSafe.Question.level() | nil} | nil
  def max_level(%__MODULE__{} = answer) do
    case ranked(answer) do
      [{level, _probability} | _] -> {level, Map.get(answer.legend, level)}
      [] -> nil
    end
  end

  @doc "Lists `{level, probability}` pairs from most to least likely. Ties go to the lower level."
  @spec ranked(t()) :: [{non_neg_integer(), float()}]
  def ranked(%__MODULE__{probabilities: probabilities}) do
    Enum.sort_by(probabilities, fn {level, probability} -> {-probability, level} end)
  end

  @doc "The Zoi schema that decodes a Score answer from the API's JSON."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc false
  @spec wire_schema() :: Zoi.schema()
  def wire_schema do
    probability = Zoi.number() |> Zoi.gte(0) |> Zoi.lte(1)

    Zoi.map(%{
      type: Zoi.literal("score"),
      score: Zoi.number(),
      legend: Zoi.map(Zoi.string(), Schema.level_json(), []),
      probabilities: Zoi.map(Zoi.string(), probability, []),
      confidence: probability
    })
  end

  @doc false
  @spec wire_json_schema() :: map()
  def wire_json_schema do
    level_key = %{type: :string, pattern: "^[0-9]+$"}
    probability = Zoi.number() |> Zoi.gte(0) |> Zoi.lte(1) |> Schema.encode_json()

    wire_schema()
    |> Schema.encode_json()
    |> put_in([:properties, :legend], Schema.object_of(Schema.encode_json(Schema.level_json()), key: level_key))
    |> put_in([:properties, :probabilities], Schema.object_of(probability, key: level_key))
  end

  @doc """
  Decodes a Score answer from the API's JSON (a map with string keys).

      iex> wire = %{"type" => "score", "score" => 1, "legend" => %{"0" => "Low", "1" => "High"}, "probabilities" => %{"0" => 0, "1" => 1}, "confidence" => 1}
      iex> {:ok, answer} = TypeSafe.Answer.Score.from_wire(wire)
      iex> answer.probabilities
      %{0 => 0.0, 1 => 1.0}
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, [Zoi.Error.t()]}
  def from_wire(map), do: Zoi.parse(@schema, map)
end
