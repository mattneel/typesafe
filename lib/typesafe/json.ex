defmodule TypeSafe.JSON do
  @moduledoc false

  # JSON encoding and decoding on top of the standard library's `JSON` module.
  #
  # Request bodies are built as plain data plus `TypeSafe.JSON.Object` values, which keep
  # object keys in the order the caller gave them. Option order is part of what the model
  # reads, so a keyword list of Choice options must reach the wire in that order; a plain
  # Elixir map cannot promise that. The custom encoder function below handles the ordered
  # objects without implementing `JSON.Encoder` for any public struct.

  defmodule Object do
    @moduledoc false
    defstruct pairs: []

    @type t :: %__MODULE__{pairs: [{String.t(), term()}]}
  end

  @doc false
  @spec object([{String.t(), term()}]) :: Object.t()
  def object(pairs) when is_list(pairs), do: %Object{pairs: pairs}

  @doc false
  @spec encode(term()) :: {:ok, iodata()} | {:error, Exception.t()}
  def encode(term) do
    {:ok, JSON.encode_to_iodata!(term, &encode_value/2)}
  rescue
    exception -> {:error, exception}
  end

  @doc false
  @spec encode!(term()) :: String.t()
  def encode!(term) do
    term |> JSON.encode_to_iodata!(&encode_value/2) |> IO.iodata_to_binary()
  end

  defp encode_value(%Object{pairs: pairs}, encoder), do: :json.encode_key_value_list(pairs, encoder)
  defp encode_value(value, encoder), do: JSON.protocol_encode(value, encoder)

  @doc false
  @spec decode(iodata()) :: {:ok, term()} | {:error, term()}
  def decode(data) do
    data |> IO.iodata_to_binary() |> JSON.decode()
  end

  @doc false
  # Converts ordered objects back into plain maps, for callers that want ordinary data.
  @spec to_plain(term()) :: term()
  def to_plain(%Object{pairs: pairs}), do: Map.new(pairs, fn {key, value} -> {key, to_plain(value)} end)
  def to_plain(list) when is_list(list), do: Enum.map(list, &to_plain/1)
  def to_plain(%{__struct__: _} = struct), do: struct
  def to_plain(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, to_plain(value)} end)
  def to_plain(other), do: other

  @doc false
  # Pretty, deterministic JSON (sorted keys, two-space indent) for checked-in schema files.
  @spec pretty(term()) :: String.t()
  def pretty(term), do: IO.iodata_to_binary([pretty(term, 0), ?\n])

  defp pretty(map, _depth) when is_map(map) and map_size(map) == 0 and not is_struct(map), do: "{}"

  defp pretty(map, depth) when is_map(map) and not is_struct(map) do
    inner = indent(depth + 1)

    entries =
      map
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_intersperse(",\n", fn {key, value} -> [inner, JSON.encode!(key), ": ", pretty(value, depth + 1)] end)

    ["{\n", entries, ?\n, indent(depth), ?}]
  end

  defp pretty([], _depth), do: "[]"

  defp pretty(list, depth) when is_list(list) do
    inner = indent(depth + 1)
    entries = Enum.map_intersperse(list, ",\n", &[inner, pretty(&1, depth + 1)])
    ["[\n", entries, ?\n, indent(depth), ?]]
  end

  defp pretty(value, _depth), do: JSON.encode!(value)

  defp indent(depth), do: String.duplicate("  ", depth)
end
