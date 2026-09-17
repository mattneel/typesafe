defmodule TypeSafe.Question.Score do
  @moduledoc """
  A question that rates the state against ordered levels you define. The answer carries a
  probability-weighted score (which can land between levels), a probability for every level,
  and a confidence.

  Build one with `TypeSafe.score/3` or `new/3`:

      iex> TypeSafe.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
      %TypeSafe.Question.Score{
        instructions: "How frustrated is the customer?",
        criteria: ["Calm", "Frustrated", "Very angry"],
        extra: %{}
      }

  Criteria are an ordered list of at least two levels; a level's position is its score,
  starting at zero. Each level accepts JSON structure (a string, a map or a list) but not
  `nil`, which the API rejects.

  See [Score](https://docs.typesafe.ai/primitives/score.md) in the TypeSafe docs.
  """

  alias TypeSafe.Schema

  @fields %{
    instructions: Schema.entry(),
    criteria:
      Schema.level()
      |> Zoi.list()
      |> Zoi.min(2, error: "score criteria needs at least two levels")
      |> Schema.list("score criteria must be a list of levels"),
    extra: Schema.extra()
  }

  @schema Zoi.struct(__MODULE__, @fields)

  defstruct [:instructions, criteria: [], extra: %{}]

  @type t :: unquote(Zoi.type_spec(@schema))

  @doc """
  Builds and validates a Score question.

  ## Options

    * `:extra` - a map of additional wire fields to send with the question.

  Returns `{:error, %TypeSafe.Error{type: :invalid_request}}` when criteria is not a list, has
  fewer than two levels, or holds a `nil` or non-JSON level.

      iex> {:ok, score} = TypeSafe.Question.Score.new("Urgency?", ["Can wait", "Today"])
      iex> score.criteria
      ["Can wait", "Today"]

      iex> {:error, error} = TypeSafe.Question.Score.new("Urgency?", ["Only one"])
      iex> error.message
      "score criteria needs at least two levels"
  """
  @spec new(TypeSafe.Question.entry(), [TypeSafe.Question.level()], keyword()) ::
          {:ok, t()} | {:error, TypeSafe.Error.t()}
  def new(instructions, criteria, opts \\ []) do
    Schema.build_question(@schema, %__MODULE__{instructions: instructions, criteria: criteria}, opts)
  end

  @doc "The Zoi schema that validates a Score question struct."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc false
  @spec wire_schema() :: Zoi.schema()
  def wire_schema do
    Schema.question_wire_schema("score", Zoi.min(Zoi.array(Schema.level_json()), 2))
  end

  @doc """
  Returns the question as the API's JSON structure, with string keys.

      iex> TypeSafe.Question.Score.to_wire(TypeSafe.score("Urgency?", ["Low", "High"]))
      %{"type" => "score", "instructions" => "Urgency?", "criteria" => ["Low", "High"]}
  """
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = question), do: question |> wire() |> TypeSafe.JSON.to_plain()

  @doc false
  @spec wire(t()) :: TypeSafe.JSON.Object.t()
  def wire(%__MODULE__{instructions: instructions, criteria: criteria, extra: extra}) do
    TypeSafe.JSON.object(
      [{"type", "score"}, {"instructions", instructions}, {"criteria", criteria}] ++ Schema.extra_pairs(extra || %{})
    )
  end
end
