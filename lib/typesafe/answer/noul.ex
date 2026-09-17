defmodule TypeSafe.Answer.Noul do
  @moduledoc """
  The answer to a `TypeSafe.Question.Noul`: the probability, from 0 to 1, that the answer is yes.

      iex> answer = %TypeSafe.Answer.Noul{noul: 0.92}
      iex> TypeSafe.Answer.Noul.yes?(answer)
      true
      iex> TypeSafe.Answer.Noul.yes?(answer, 0.95)
      false

  The value is a calibrated probability, not a verdict. Your code picks the threshold, and can
  treat the middle of the range as "not sure" and route it elsewhere. See
  [Confidence](https://docs.typesafe.ai/confidence.md).
  """

  alias TypeSafe.Schema

  @fields %{noul: Schema.probability()}

  @schema Zoi.struct(__MODULE__, @fields, coerce: true)

  defstruct [:noul]

  @type t :: unquote(Zoi.type_spec(@schema))

  @doc """
  Returns `true` when the probability of yes is at least `threshold` (default `0.5`).

      iex> TypeSafe.Answer.Noul.yes?(%TypeSafe.Answer.Noul{noul: 0.5})
      true
      iex> TypeSafe.Answer.Noul.yes?(%TypeSafe.Answer.Noul{noul: 0.3}, 0.25)
      true
  """
  @spec yes?(t(), number()) :: boolean()
  def yes?(%__MODULE__{noul: noul}, threshold \\ 0.5) when is_number(threshold), do: noul >= threshold

  @doc "The Zoi schema that decodes a Noul answer from the API's JSON."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc false
  @spec wire_schema() :: Zoi.schema()
  def wire_schema do
    Zoi.map(%{type: Zoi.literal("noul"), noul: Zoi.number() |> Zoi.gte(0) |> Zoi.lte(1)})
  end

  @doc """
  Decodes a Noul answer from the API's JSON (a map with string keys).

      iex> TypeSafe.Answer.Noul.from_wire(%{"type" => "noul", "noul" => 1})
      {:ok, %TypeSafe.Answer.Noul{noul: 1.0}}
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, [Zoi.Error.t()]}
  def from_wire(map), do: Zoi.parse(@schema, map)
end
