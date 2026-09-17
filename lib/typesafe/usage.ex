defmodule TypeSafe.Usage do
  @moduledoc """
  Token usage reported for one System One request.

  Both counts are optional: TypeSafe's official Python SDK documents them as possibly absent, so a response
  without them still decodes, with `nil` in place of the missing count.
  """

  @fields %{
    input_tokens: [description: "Billable input tokens."] |> Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish(),
    output_tokens:
      [description: "Output tokens (currently free of charge)."] |> Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish()
  }

  @schema Zoi.struct(__MODULE__, @fields, coerce: true)

  defstruct [:input_tokens, :output_tokens]

  @type t :: unquote(Zoi.type_spec(@schema))

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc false
  @spec wire_schema() :: Zoi.schema()
  def wire_schema, do: Zoi.map(@fields)

  @doc false
  @spec from_wire(term()) :: {:ok, t()} | {:error, [Zoi.Error.t()]}
  def from_wire(nil), do: {:ok, %__MODULE__{}}
  def from_wire(map), do: Zoi.parse(@schema, map)
end
