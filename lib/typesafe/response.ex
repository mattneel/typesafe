defmodule TypeSafe.Response do
  @moduledoc """
  The result of `TypeSafe.ask/4`: one answer per question, plus the model and token usage.

    * `answers` - a map from each question id to its answer struct, keyed exactly as you keyed
      the questions (atoms stay atoms, strings stay strings).
    * `model` - the model that answered, which may be a concrete version of the alias you asked
      for (for example `"jev-1.13.0"` for `"jev-latest"`).
    * `usage` - a `TypeSafe.Usage` with input and output token counts.
    * `request_id` - the `x-typesafe-request-id` header, useful when contacting support.
    * `raw` - the decoded JSON body, including any answer of a type this SDK does not know.

  ## Reading answers

      iex> response = %TypeSafe.Response{
      ...>   model: "jev-1.13.0",
      ...>   answers: %{is_urgent: %TypeSafe.Answer.Noul{noul: 0.92}},
      ...>   usage: %TypeSafe.Usage{input_tokens: 312, output_tokens: 48}
      ...> }
      iex> response.answers.is_urgent.noul
      0.92
      iex> TypeSafe.Response.fetch!(response, :is_urgent).noul
      0.92
      iex> TypeSafe.Response.fetch(response, :missing)
      :error
  """

  alias TypeSafe.Answer
  alias TypeSafe.Usage

  defstruct [:model, :request_id, :raw, answers: %{}, usage: %Usage{}]

  @type t :: %__MODULE__{
          model: String.t(),
          answers: %{optional(TypeSafe.Question.id()) => Answer.t()},
          usage: Usage.t(),
          request_id: String.t() | nil,
          raw: map() | nil
        }

  @doc """
  Returns `{:ok, answer}` for a question id, or `:error` when the response has no answer for it.
  """
  @spec fetch(t(), TypeSafe.Question.id()) :: {:ok, Answer.t()} | :error
  def fetch(%__MODULE__{answers: answers}, id), do: Map.fetch(answers, id)

  @doc """
  Returns the answer for a question id, raising `KeyError` when there is none.

  The error names the missing id and lists the ids that do have answers, which catches a
  mistyped id or an atom/string mix-up quickly.
  """
  @spec fetch!(t(), TypeSafe.Question.id()) :: Answer.t()
  def fetch!(%__MODULE__{answers: answers} = response, id) do
    case Map.fetch(answers, id) do
      {:ok, answer} ->
        answer

      :error ->
        available = answers |> Map.keys() |> Enum.sort_by(&to_string/1)

        raise KeyError,
          key: id,
          term: response,
          message: "no TypeSafe answer for question id #{inspect(id)}; answers exist for #{inspect(available)}"
    end
  end

  @doc """
  Returns only the Noul answers, keyed by question id.

      iex> response = %TypeSafe.Response{answers: %{a: %TypeSafe.Answer.Noul{noul: 0.1}, b: %TypeSafe.Answer.Choice{choice: "x", probabilities: %{"x" => 1.0}, confidence: 1.0}}}
      iex> TypeSafe.Response.nouls(response)
      %{a: %TypeSafe.Answer.Noul{noul: 0.1}}
  """
  @spec nouls(t()) :: %{optional(TypeSafe.Question.id()) => Answer.Noul.t()}
  def nouls(%__MODULE__{} = response), do: filter(response, Answer.Noul)

  @doc "Returns only the Choice answers, keyed by question id."
  @spec choices(t()) :: %{optional(TypeSafe.Question.id()) => Answer.Choice.t()}
  def choices(%__MODULE__{} = response), do: filter(response, Answer.Choice)

  @doc "Returns only the Score answers, keyed by question id."
  @spec scores(t()) :: %{optional(TypeSafe.Question.id()) => Answer.Score.t()}
  def scores(%__MODULE__{} = response), do: filter(response, Answer.Score)

  defp filter(%__MODULE__{answers: answers}, module) do
    for {id, %^module{} = answer} <- answers, into: %{}, do: {id, answer}
  end

  @doc false
  @spec wire_schema() :: Zoi.schema()
  def wire_schema do
    Zoi.map(%{
      model: Zoi.string(),
      answers: Zoi.map(Zoi.string(), Answer.wire_schema(), []),
      usage: Zoi.optional(Usage.wire_schema())
    })
  end

  @top_schema Zoi.map(
                %{model: Zoi.string(), answers: Zoi.map(Zoi.string(), Zoi.any(), []), usage: Zoi.optional(Zoi.any())},
                coerce: true
              )

  @doc false
  # Decodes a 2xx body. `prepared` carries the lookups from `TypeSafe.Question.prepare/1` that
  # map wire ids and Choice options back to the caller's keys.
  @spec from_wire(term(), String.t() | nil, map()) :: {:ok, t()} | {:error, TypeSafe.Error.t()}
  def from_wire(body, request_id, prepared \\ %{ids: %{}, options: %{}})

  def from_wire(%{} = body, request_id, prepared) when not is_struct(body) do
    with {:ok, top} <- parse(@top_schema, body, []),
         {:ok, usage} <- body |> Map.get("usage") |> Usage.from_wire() |> wrap(["usage"]),
         {:ok, answers} <- decode_answers(top.answers, prepared) do
      {:ok, %__MODULE__{model: top.model, answers: answers, usage: usage, request_id: request_id, raw: body}}
    end
  end

  def from_wire(body, _request_id, _prepared) do
    {:error,
     TypeSafe.Error.invalid(
       :invalid_response,
       "expected a JSON object response body, got: #{inspect(body, limit: 5)}",
       []
     )}
  end

  defp decode_answers(raw_answers, prepared) do
    ids = Map.get(prepared, :ids, %{})
    options = Map.get(prepared, :options, %{})

    raw_answers
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {wire_id, raw}, {:ok, acc} ->
      case Answer.from_wire(wire_id, raw, Map.get(options, wire_id, %{})) do
        {:ok, answer} -> {:cont, {:ok, Map.put(acc, Map.get(ids, wire_id, wire_id), answer)}}
        :skip -> {:cont, {:ok, acc}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp parse(schema, value, prefix), do: schema |> Zoi.parse(value) |> wrap(prefix)

  defp wrap({:ok, value}, _prefix), do: {:ok, value}
  defp wrap({:error, errors}, prefix), do: {:error, TypeSafe.Error.from_zoi(errors, :invalid_response, prefix)}
end
