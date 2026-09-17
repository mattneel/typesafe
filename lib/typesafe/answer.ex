defmodule TypeSafe.Answer do
  @moduledoc """
  The answer types, one per question type, and the decoding that turns the API's JSON into
  them.

  | Answer | Fields | Helpers |
  | --- | --- | --- |
  | `TypeSafe.Answer.Noul` | `noul` | `yes?/2` |
  | `TypeSafe.Answer.Choice` | `choice`, `probabilities`, `confidence` | `ranked/1`, `margin/1` |
  | `TypeSafe.Answer.Score` | `score`, `legend`, `probabilities`, `confidence` | `expected_level/1`, `max_level/1`, `ranked/1` |

  Answers are decoded by their wire `type`. An answer whose type this version of the SDK does
  not know is skipped with a warning instead of failing the whole response, and stays readable
  in `TypeSafe.Response`'s `raw` field. This matches the forward-compatibility rule of TypeSafe's
  official Python SDK, so a new question type on the server never breaks an existing client.
  """

  alias TypeSafe.Answer.Choice
  alias TypeSafe.Answer.Noul
  alias TypeSafe.Answer.Score

  require Logger

  @typedoc "Any TypeSafe answer."
  @type t :: Noul.t() | Choice.t() | Score.t()

  @doc """
  Decodes one answer from the API's JSON.

  `options` maps Choice option strings back to the caller's keys. Returns `:skip` for an
  answer type this SDK does not know, after logging a warning.

      iex> TypeSafe.Answer.from_wire("is_urgent", %{"type" => "noul", "noul" => 0.92})
      {:ok, %TypeSafe.Answer.Noul{noul: 0.92}}

      iex> {:error, error} = TypeSafe.Answer.from_wire("is_urgent", %{"type" => "noul", "noul" => 2})
      iex> {error.type, error.path}
      {:invalid_response, ["answers", "is_urgent", "noul"]}
  """
  @spec from_wire(String.t(), term(), %{String.t() => TypeSafe.Question.Choice.option()}) ::
          {:ok, t()} | :skip | {:error, TypeSafe.Error.t()}
  def from_wire(id, raw, options \\ %{})

  def from_wire(id, %{"type" => type} = raw, options) when is_binary(type) do
    result =
      case type do
        "noul" -> Noul.from_wire(raw)
        "choice" -> Choice.from_wire(raw, options)
        "score" -> Score.from_wire(raw)
        _unknown -> :skip
      end

    case result do
      {:ok, answer} ->
        {:ok, answer}

      :skip ->
        Logger.warning("TypeSafe: ignoring answer #{inspect(id)} with unrecognized type #{inspect(type)}")
        :skip

      {:error, errors} ->
        {:error, TypeSafe.Error.from_zoi(errors, :invalid_response, ["answers", id])}
    end
  end

  def from_wire(id, raw, _options) do
    message =
      if is_map(raw),
        do: "answer is missing its string \"type\"",
        else: "expected answer to be a JSON object, got: #{inspect(raw, limit: 5)}"

    {:error, TypeSafe.Error.invalid(:invalid_response, message, ["answers", id, "type"])}
  end

  @doc false
  @spec wire_schema() :: Zoi.schema()
  def wire_schema do
    Zoi.discriminated_union(:type, [Noul.wire_schema(), Choice.wire_schema(), Score.wire_schema()])
  end

  @doc false
  @spec wire_json_schema() :: map()
  def wire_json_schema do
    TypeSafe.Schema.one_of("type", [
      TypeSafe.Schema.encode_json(Noul.wire_schema()),
      Choice.wire_json_schema(),
      Score.wire_json_schema()
    ])
  end
end
