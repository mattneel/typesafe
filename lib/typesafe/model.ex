defmodule TypeSafe.Model do
  @moduledoc """
  A model or model alias available to your account, as returned by `TypeSafe.list_models/2`.

  Pass `name` as the `:model` option to `TypeSafe.new/1` or `TypeSafe.ask/4`. `release_date` is
  kept exactly as the API sends it (an ISO 8601 date or timestamp string), so a format change on
  the server never breaks decoding.
  """

  @fields %{
    name: Zoi.string(description: "Model name or alias accepted by the `model` option."),
    description: Zoi.string(description: "Human-readable description of the model."),
    release_date: Zoi.string(description: "Release date as an ISO 8601 string.")
  }

  @schema Zoi.struct(__MODULE__, @fields, coerce: true)

  defstruct [:name, :description, :release_date]

  @type t :: unquote(Zoi.type_spec(@schema))

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc false
  @spec list_wire_schema() :: Zoi.schema()
  def list_wire_schema, do: Zoi.map(%{models: Zoi.array(Zoi.map(@fields))})

  @doc false
  @spec from_wire(term()) :: {:ok, t()} | {:error, [Zoi.Error.t()]}
  def from_wire(map), do: Zoi.parse(@schema, map)
end
