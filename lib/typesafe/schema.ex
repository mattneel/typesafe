defmodule TypeSafe.Schema do
  @moduledoc false

  # Zoi building blocks shared by the question, answer and response schemas, so each wire
  # concept (an entry, a level, a probability, a key) is defined exactly once.
  #
  # Entries are validated with a strict recursive JSON check rather than a union of Zoi
  # types, because Zoi's array type accepts tuples and would silently turn them into lists.
  # The SDK passes caller data through untouched, so anything that is not JSON is rejected
  # with a path to the offending value. The `*_json` variants describe the same shapes as
  # unions for the published JSON Schema files.

  @doc false
  # The wire's `EntryType`: a string, a JSON object, an array, or null.
  @spec entry() :: Zoi.schema()
  def entry do
    Zoi.refine(Zoi.any(typespec: quote(do: TypeSafe.Question.entry())), {__MODULE__, :validate_entry, [:entry]})
  end

  @doc false
  # A Score level: a string, a JSON object or an array. The API rejects null levels.
  @spec level() :: Zoi.schema()
  def level do
    Zoi.refine(Zoi.any(typespec: quote(do: TypeSafe.Question.level())), {__MODULE__, :validate_entry, [:level]})
  end

  @doc false
  # Wraps a Zoi list schema so the value must already be a proper list. Zoi's array type accepts
  # a tuple and parses it as a list, but constructors keep the caller's value, so a tuple would
  # pass validation and then fail to encode as JSON; an improper list would make Zoi raise.
  @spec list(Zoi.schema(), String.t()) :: Zoi.schema()
  def list(list_schema, error) do
    Zoi.intersection([Zoi.refine(Zoi.any(), {__MODULE__, :validate_list, [error]}), list_schema],
      typespec: Zoi.type_spec(list_schema)
    )
  end

  @doc false
  @spec validate_list(term(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_list(value, error, _opts), do: if(proper_list?(value), do: :ok, else: {:error, error})

  @doc false
  # The wire shape shared by the three question types, for the published JSON Schema.
  @spec question_wire_schema(String.t(), Zoi.schema()) :: Zoi.schema()
  def question_wire_schema(type, criteria) do
    Zoi.map(%{type: Zoi.literal(type), instructions: Zoi.optional(entry_json()), criteria: criteria})
  end

  @doc false
  @spec entry_json() :: Zoi.schema()
  def entry_json do
    Zoi.union([Zoi.string(), Zoi.map(Zoi.string(), Zoi.any(), []), Zoi.array(Zoi.any()), Zoi.null()])
  end

  @doc false
  @spec level_json() :: Zoi.schema()
  def level_json do
    Zoi.union([Zoi.string(), Zoi.map(Zoi.string(), Zoi.any(), []), Zoi.array(Zoi.any())])
  end

  @doc false
  # Extra wire fields for a question, for API fields newer than this SDK.
  @spec extra() :: Zoi.schema()
  def extra do
    Zoi.refine(
      Zoi.map(Zoi.any(), Zoi.any(), typespec: quote(do: %{optional(atom() | String.t()) => term()})),
      {__MODULE__, :validate_extra, []}
    )
  end

  @reserved_fields ~w(type instructions criteria)
  @max_float 1.797_693_134_862_315_7e308

  @doc false
  @spec validate_extra(map(), keyword()) :: :ok | {:error, String.t() | Zoi.Error.t()}
  def validate_extra(extra, _opts) do
    Enum.find_value(extra, :ok, fn {key, value} ->
      cond do
        not ((is_atom(key) and key not in [nil, :""]) or (is_binary(key) and key != "")) ->
          {:error, "extra field names must be atoms or non-empty strings, got: #{inspect(key)}"}

        key_to_string(key) in @reserved_fields ->
          {:error, "extra cannot set the reserved field #{inspect(key_to_string(key))}"}

        issue = json_issue(value, [key]) ->
          {message, path} = issue
          {:error, %Zoi.Error{code: :custom, message: message, issue: {message, []}, path: Enum.reverse(path)}}

        true ->
          nil
      end
    end)
  end

  @doc false
  @spec extra_pairs(map()) :: [{String.t(), term()}]
  def extra_pairs(extra) do
    extra |> Enum.map(fn {key, value} -> {key_to_string(key), value} end) |> Enum.sort_by(&elem(&1, 0))
  end

  @doc false
  # Shared by the three question constructors: applies the `:extra` option to a question built
  # from the caller's arguments, then validates the whole struct against its schema.
  @spec build_question(Zoi.schema(), struct(), keyword()) :: {:ok, struct()} | {:error, TypeSafe.Error.t()}
  def build_question(schema, question, opts) do
    with {:ok, opts} <- question_opts(opts, [:extra]) do
      question = %{question | extra: Keyword.get(opts, :extra, %{})}

      case Zoi.parse(schema, question) do
        {:ok, _parsed} -> {:ok, question}
        {:error, errors} -> {:error, TypeSafe.Error.from_zoi(errors, :invalid_request, [])}
      end
    end
  end

  @doc false
  # Validates constructor options shared by the three question types.
  @spec question_opts(keyword(), [atom()]) :: {:ok, keyword()} | {:error, TypeSafe.Error.t()}
  def question_opts(opts, allowed) when is_list(opts) do
    case Keyword.keyword?(opts) && Keyword.keys(opts) -- allowed do
      [] ->
        {:ok, opts}

      false ->
        {:error, TypeSafe.Error.invalid_request("expected question options as a keyword list, got: #{inspect(opts)}")}

      unknown ->
        {:error,
         TypeSafe.Error.invalid_request("unknown question options #{inspect(unknown)}; allowed: #{inspect(allowed)}")}
    end
  end

  def question_opts(opts, _allowed) do
    {:error, TypeSafe.Error.invalid_request("expected question options as a keyword list, got: #{inspect(opts)}")}
  end

  @doc false
  # A caller-chosen key (question id or Choice option): an atom or a non-empty string.
  @spec key() :: Zoi.schema()
  def key do
    Zoi.refine(Zoi.any(typespec: quote(do: atom() | String.t())), {__MODULE__, :validate_key, []})
  end

  @doc false
  # A probability-like number in 0..1, always returned as a float.
  @spec probability() :: Zoi.schema()
  def probability do
    [typespec: quote(do: float())]
    |> Zoi.number()
    |> Zoi.gte(0)
    |> Zoi.lte(1)
    |> Zoi.transform({__MODULE__, :to_float, []})
  end

  @doc false
  @spec number() :: Zoi.schema()
  def number do
    Zoi.transform(Zoi.number(typespec: quote(do: float())), {__MODULE__, :to_float, []})
  end

  @doc false
  # A non-negative integer map key that arrives as a JSON string such as "0".
  @spec level_index() :: Zoi.schema()
  def level_index do
    [typespec: quote(do: non_neg_integer())] |> Zoi.integer() |> Zoi.coerce() |> Zoi.gte(0)
  end

  @doc false
  # JSON integers are unbounded; one outside the float range is an invalid number, not a crash.
  @spec to_float(number(), keyword()) :: float() | {:error, String.t()}
  def to_float(value, _opts) when is_float(value), do: value
  def to_float(value, _opts) when value >= -@max_float and value <= @max_float, do: value * 1.0
  def to_float(_value, _opts), do: {:error, "number is too large"}

  @doc false
  @spec validate_key(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_key(key, _opts) when is_atom(key) and key not in [nil, :""], do: :ok
  def validate_key(key, _opts) when is_binary(key) and key != "", do: :ok
  def validate_key(_key, _opts), do: {:error, "expected an atom or a non-empty string"}

  @doc false
  @spec validate_entry(term(), :entry | :level, keyword()) :: :ok | {:error, String.t() | Zoi.Error.t()}
  def validate_entry(nil, :entry, _opts), do: :ok
  def validate_entry(nil, :level, _opts), do: {:error, "expected a string, map or list (levels cannot be nil)"}

  def validate_entry(value, _kind, _opts) when is_binary(value) or is_list(value) or is_map(value) do
    case json_issue(value, []) do
      nil ->
        :ok

      {message, path} ->
        {:error, %Zoi.Error{code: :custom, message: message, issue: {message, []}, path: Enum.reverse(path)}}
    end
  end

  def validate_entry(_value, :entry, _opts), do: {:error, "expected a string, map, list or nil"}
  def validate_entry(_value, :level, _opts), do: {:error, "expected a string, map or list"}

  @doc false
  # Returns nil when `value` encodes as JSON, or `{message, reversed_path}` for the first value
  # that does not.
  @spec json_issue(term(), [term()]) :: nil | {String.t(), [term()]}
  def json_issue(value, path) when is_binary(value) do
    if String.valid?(value), do: nil, else: {"expected valid UTF-8 text", path}
  end

  def json_issue(value, _path) when is_number(value) or is_atom(value), do: nil

  def json_issue(value, path) when is_list(value), do: list_issue(value, 0, path)

  def json_issue(%{__struct__: module} = value, path) do
    if JSON.Encoder.impl_for(value),
      do: nil,
      else: {"expected JSON data, got a #{inspect(module)} struct that does not implement JSON.Encoder", path}
  end

  def json_issue(value, path) when is_map(value) do
    Enum.find_value(value, fn {key, item} ->
      if is_binary(key) or is_atom(key) or is_number(key),
        do: json_issue(item, [key | path]),
        else: {"expected JSON object keys to be strings, atoms or numbers, got #{inspect(key)}", path}
    end)
  end

  def json_issue(value, path), do: {"expected JSON data, got #{inspect(value)}", path}

  defp list_issue([], _index, _path), do: nil
  defp list_issue([item | rest], index, path), do: json_issue(item, [index | path]) || list_issue(rest, index + 1, path)
  defp list_issue(_improper_tail, _index, path), do: {"expected JSON data, got an improper list", path}

  @doc false
  # `is_list/1` is also true for an improper list such as `[1 | 2]`, which Enum and Zoi's array
  # type cannot walk and JSON cannot represent.
  @spec proper_list?(term()) :: boolean()
  def proper_list?([]), do: true
  def proper_list?([_item | rest]), do: proper_list?(rest)
  def proper_list?(_other), do: false

  @doc false
  # The wire contract as JSON Schema documents, keyed by file name. These are the files kept in
  # priv/json_schema and regenerated with `mix typesafe.schema`.
  @spec json_schemas() :: %{String.t() => map()}
  def json_schemas do
    request =
      Zoi.map(%{
        state: Zoi.union([Zoi.string(), Zoi.map(Zoi.string(), Zoi.any(), []), Zoi.array(Zoi.any())]),
        model: Zoi.string(),
        questions: Zoi.map(Zoi.string(), Zoi.any(), [])
      })

    request_json =
      put_in(
        encode_json(request),
        [:properties, :questions],
        object_of(TypeSafe.Question.wire_json_schema(), min: 1, key: %{type: :string, minLength: 1})
      )

    response_json =
      put_in(
        encode_json(TypeSafe.Response.wire_schema()),
        [:properties, :answers],
        object_of(TypeSafe.Answer.wire_json_schema())
      )

    %{
      "request" => document(request_json, "SystemOneRequest", "POST /v1/systemone request body"),
      "response" => document(response_json, "SystemOneResponse", "POST /v1/systemone response body"),
      "models" =>
        document(encode_json(TypeSafe.Model.list_wire_schema()), "ModelMetadataList", "GET /v1/models response body")
    }
  end

  @doc false
  # Zoi's encoder describes a map with typed keys and values as a bare object, so maps of that
  # kind are filled in with `object_of/2` by the modules that own them.
  @spec encode_json(Zoi.schema()) :: map()
  def encode_json(schema), do: Zoi.JSONSchema.encode_schema(schema)

  @doc false
  @spec object_of(map(), keyword()) :: map()
  def object_of(value_json, opts \\ []) do
    %{type: :object, additionalProperties: value_json}
    |> then(&if(min = opts[:min], do: Map.put(&1, :minProperties, min), else: &1))
    |> then(&if(key = opts[:key], do: Map.put(&1, :propertyNames, key), else: &1))
  end

  @doc false
  @spec one_of(String.t(), [map()]) :: map()
  def one_of(discriminator, schemas), do: %{oneOf: schemas, discriminator: %{propertyName: discriminator}}

  defp document(json, title, description) do
    json
    |> Map.merge(%{"$schema": "https://json-schema.org/draft/2020-12/schema", title: title, description: description})
    |> sort_required()
  end

  # Zoi lists required fields in map iteration order, which follows the atom table and can
  # differ between machines. Sorting keeps the checked-in files byte-for-byte stable.
  defp sort_required(%{} = json) when not is_struct(json) do
    Map.new(json, fn
      {:required, fields} when is_list(fields) -> {:required, Enum.sort_by(fields, &to_string/1)}
      {key, value} -> {key, sort_required(value)}
    end)
  end

  defp sort_required(list) when is_list(list), do: Enum.map(list, &sort_required/1)
  defp sort_required(other), do: other

  @doc false
  # Zoi reports paths as a mix of atoms, strings and integers; the SDK exposes strings.
  @spec path([atom() | String.t() | integer()]) :: [String.t()]
  def path(segments), do: Enum.map(segments, &to_string/1)

  @doc false
  @spec key_to_string(atom() | String.t()) :: String.t()
  def key_to_string(key) when is_binary(key), do: key
  def key_to_string(key) when is_atom(key), do: Atom.to_string(key)

  @doc false
  # Normalises a caller's keyed collection into ordered pairs: keyword lists and lists of pairs
  # keep their order, maps are sorted by the string form of their keys so the bytes sent are
  # deterministic across nodes and runs.
  @spec pairs(map() | list()) :: list()
  def pairs(%{} = map) when not is_struct(map), do: Enum.sort_by(map, fn {key, _} -> sort_key(key) end)
  def pairs(list) when is_list(list), do: list

  defp sort_key(key) when is_atom(key) or is_binary(key), do: {0, key_to_string(key)}
  defp sort_key(key), do: {1, key}
end
