defmodule TypeSafe.WireHelpers do
  @moduledoc false

  # Key order is part of the request contract (Choice option order changes model output), and a
  # decoded Elixir map cannot show it. These helpers decode JSON with objects kept as ordered
  # pair lists, so tests can compare the order of the keys the SDK controls.

  @typedoc "A decoded JSON value whose objects are `{:object, [{key, value}]}` in document order."
  @type ordered :: {:object, [{String.t(), ordered()}]} | [ordered()] | String.t() | number() | boolean() | nil

  @doc "Decodes JSON text or iodata, keeping every object's keys in document order."
  @spec decode_ordered(iodata()) :: ordered()
  def decode_ordered(json) do
    decoders = %{
      object_start: fn _parent_acc -> [] end,
      object_push: fn key, value, acc -> [{key, value} | acc] end,
      object_finish: fn acc, parent_acc -> {{:object, Enum.reverse(acc)}, parent_acc} end
    }

    {value, :ok, ""} = json |> IO.iodata_to_binary() |> String.trim() |> :json.decode(:ok, decoders)
    value
  end

  @doc "Returns the keys of an ordered object, in order."
  @spec keys(ordered()) :: [String.t()]
  def keys({:object, pairs}), do: Enum.map(pairs, &elem(&1, 0))

  @doc "Returns the value under `key` in an ordered object."
  @spec get(ordered(), String.t()) :: ordered()
  def get({:object, pairs}, key), do: pairs |> List.keyfind!(key, 0) |> elem(1)

  @doc """
  Normalises an ordered request body so two bodies compare equal exactly when they carry the
  same data with the same key order wherever the SDK promises one: the top-level fields, the
  question ids, each question's fields, Noul criteria and Choice options. Objects inside
  caller data (state, instructions, descriptions and levels) are plain Elixir maps whose key
  order the SDK does not control, so their keys are sorted.
  """
  @spec request_order(ordered()) :: ordered()
  def request_order({:object, fields}) do
    {:object,
     Enum.map(fields, fn
       {"questions", {:object, questions}} -> {"questions", {:object, map_values(questions, &question_order/1)}}
       {key, value} -> {key, unordered(value)}
     end)}
  end

  defp question_order({:object, fields} = question) do
    type = get(question, "type")

    {:object,
     Enum.map(fields, fn
       {"criteria", {:object, entries}} when type in ["noul", "choice"] ->
         {"criteria", {:object, map_values(entries, &unordered/1)}}

       {key, value} ->
         {key, unordered(value)}
     end)}
  end

  @doc "Sorts the keys of every object in an ordered value, for order-insensitive comparison."
  @spec unordered(ordered()) :: ordered()
  def unordered({:object, pairs}), do: {:object, pairs |> map_values(&unordered/1) |> Enum.sort()}
  def unordered(list) when is_list(list), do: Enum.map(list, &unordered/1)
  def unordered(other), do: other

  defp map_values(pairs, fun), do: Enum.map(pairs, fn {key, value} -> {key, fun.(value)} end)
end
