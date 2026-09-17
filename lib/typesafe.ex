defmodule TypeSafe do
  @moduledoc """
  Elixir client for TypeSafe's System One API (the Jev model).

  Build Choice, Noul and Score questions, send them with your application state in one
  request, and get back structs carrying probabilities that your code combines.

      client = TypeSafe.new(api_key: System.fetch_env!("TYPESAFE_API_KEY"))

      questions = %{
        is_urgent: TypeSafe.noul("Does this convey urgency?",
          criteria: %{true: "Explicitly time-sensitive", false: "No urgency expressed"}),
        department: TypeSafe.choice("Which team should handle this?",
          billing: "Payments, invoicing, refunds", technical: "Bugs, outages, integrations", sales: nil),
        frustration: TypeSafe.score("How frustrated is the customer?",
          ["Calm", "Frustrated", "Very angry"])
      }

      {:ok, %TypeSafe.Response{answers: answers}} =
        TypeSafe.ask(client, "Help! My payouts have been failing for 3 days.", questions)

      answers.is_urgent.noul            #=> 0.95
      answers.department.choice         #=> :billing
      answers.department.probabilities  #=> %{billing: 0.87, technical: 0.13, sales: 0.0}
      answers.frustration.score         #=> 1.05

  The SDK returns judgments as data. Thresholds and policy stay in your code: read the
  probabilities and confidence, decide what to do, and route uncertain cases elsewhere.

  ## Modules

    * `TypeSafe.Client` - client options and the underlying `Req.Request`.
    * `TypeSafe.Question` and `TypeSafe.Answer` - the three primitives on each side of a call.
    * `TypeSafe.Response` - answers, model and usage for one call.
    * `TypeSafe.Error` - the single error struct, matched on `:type`.
    * `TypeSafe.Retry` - the retry policy, with the same defaults as TypeSafe's official Python and
      JavaScript SDKs.
    * `TypeSafe.Telemetry` - the events emitted per call.
    * `TypeSafe.Test` - `Req.Test` stubs for your application's tests.
    * `TypeSafe.Req` - a Req plugin for teams with their own `Req.Request`.
  """

  alias TypeSafe.Client
  alias TypeSafe.Error
  alias TypeSafe.Question
  alias TypeSafe.Response
  alias TypeSafe.Telemetry

  @ask_opts [:model, :timeout, :retry, :headers, :telemetry_metadata]
  @list_models_opts [:timeout, :retry, :headers, :telemetry_metadata]

  @doc """
  Builds a client. See `TypeSafe.Client` for every option and how each one resolves.

  Raises `ArgumentError` when no API key is found or an option is invalid.

      iex> client = TypeSafe.new(api_key: "ts_test_key")
      iex> client.model
      "jev-latest"
  """
  @spec new(keyword()) :: Client.t()
  def new(opts \\ []), do: Client.new(opts)

  @doc """
  Asks questions about `state` in one request.

  `state` is the content to judge: a string, or a map or list sent as JSON structure (never
  stringified). `questions` is a map or keyword list of questions keyed by ids you choose; the
  answers come back under the same ids with the same key type.

  Questions are validated before anything is sent; a problem returns
  `{:error, %TypeSafe.Error{type: :invalid_request}}` with the offending `path`.

  ## Options

    * `:model` - the model for this call, overriding the client's (default `"jev-latest"`).
    * `:timeout` - receive timeout in milliseconds for this call.
    * `:retry` - retry options merged over the client's policy (or over the defaults when the
      client has `retry: false`), a `TypeSafe.Retry` that replaces it, or `false` for this call.
    * `:headers` - extra headers for this call, merged over the client's.
    * `:telemetry_metadata` - a map added to the telemetry events as `:telemetry_metadata`.

  A 2xx response whose body does not match the response schema returns
  `{:error, %TypeSafe.Error{type: :invalid_response}}` carrying the response's status, request
  id, headers and body.

  ## Examples

      TypeSafe.ask(client, "I was charged twice.", %{billing: TypeSafe.noul("Is this about billing?")})
      #=> {:ok, %TypeSafe.Response{answers: %{billing: %TypeSafe.Answer.Noul{noul: 0.97}}, ...}}

      TypeSafe.ask(client, %{subject: "Refund", body: "..."}, [tone: TypeSafe.choice("Tone?", [:calm, :angry])],
        model: "jev-preview", retry: false)

  With `TypeSafe.Test` stubs in place of the API:

      iex> client = TypeSafe.new(api_key: "ts_test_key", req_options: [plug: {Req.Test, TypeSafe}])
      iex> TypeSafe.Test.stub_answers(%{billing: {:noul, 0.97}}, request_id: "req_doc")
      iex> {:ok, response} = TypeSafe.ask(client, "I was charged twice.", %{billing: TypeSafe.noul("Is this about billing?")})
      iex> {response.answers.billing.noul, response.request_id}
      {0.97, "req_doc"}

      iex> client = TypeSafe.new(api_key: "ts_test_key", retry: false, req_options: [plug: {Req.Test, TypeSafe}])
      iex> TypeSafe.Test.stub_error(429, retry_after_ms: 1_500)
      iex> {:error, error} = TypeSafe.ask(client, "state", %{spam: TypeSafe.noul("Is this spam?")})
      iex> {error.type, error.status, error.retry_after_ms}
      {:rate_limited, 429, 1500}
  """
  @spec ask(Client.t(), String.t() | map() | list(), Question.questions(), keyword()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def ask(%Client{} = client, state, questions, opts \\ []) do
    opts = check_opts!(opts, @ask_opts, "TypeSafe.ask/4")
    model = opts[:model] || client.model
    ids = Question.ids(questions)

    metadata = %{
      operation: :ask,
      model: model,
      question_count: length(ids),
      question_ids: ids,
      base_url: client.base_url,
      telemetry_metadata: opts[:telemetry_metadata] || %{}
    }

    Telemetry.request_span(metadata, fn ->
      {result, info} = do_ask(client, state, questions, model, opts)
      stop(result, info)
    end)
  end

  @doc """
  Like `ask/4`, but returns the response directly and raises `TypeSafe.Error` on failure.

      iex> client = TypeSafe.new(api_key: "ts_test_key", req_options: [plug: {Req.Test, TypeSafe}])
      iex> TypeSafe.Test.stub_answers(%{tone: {:choice, :calm, %{calm: 0.8, angry: 0.2}}})
      iex> TypeSafe.ask!(client, "Thanks!", %{tone: TypeSafe.choice("Tone?", [:calm, :angry])}).answers.tone.choice
      :calm

      iex> client = TypeSafe.new(api_key: "ts_test_key", req_options: [plug: {Req.Test, TypeSafe}])
      iex> TypeSafe.Test.stub_error(401, request_id: "req_doc")
      iex> TypeSafe.ask!(client, "state", %{spam: TypeSafe.noul("Is this spam?")})
      ** (TypeSafe.Error) authentication (HTTP 401): Unauthorized [endpoint: POST https://api.typesafe.ai/v1/systemone, request_id: req_doc]
  """
  @spec ask!(Client.t(), String.t() | map() | list(), Question.questions(), keyword()) :: Response.t()
  def ask!(%Client{} = client, state, questions, opts \\ []) do
    case ask(client, state, questions, opts) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end

  @doc """
  Lists the models and aliases available to your account (`GET /v1/models`).

  Accepts the `:timeout`, `:retry`, `:headers` and `:telemetry_metadata` options of `ask/4`.

      TypeSafe.list_models(client)
      #=> {:ok, [%TypeSafe.Model{name: "jev-latest", description: "...", release_date: "2026-09-10T18:38:01Z"}, ...]}

  With a `TypeSafe.Test` stub in place of the API:

      iex> client = TypeSafe.new(api_key: "ts_test_key", req_options: [plug: {Req.Test, TypeSafe}])
      iex> TypeSafe.Test.stub_models([%{name: "jev-latest", description: "Latest", release_date: "2026-09-10"}])
      iex> TypeSafe.list_models(client)
      {:ok, [%TypeSafe.Model{name: "jev-latest", description: "Latest", release_date: "2026-09-10"}]}
  """
  @spec list_models(Client.t(), keyword()) :: {:ok, [TypeSafe.Model.t()]} | {:error, Error.t()}
  def list_models(%Client{} = client, opts \\ []) do
    opts = check_opts!(opts, @list_models_opts, "TypeSafe.list_models/2")

    metadata = %{
      operation: :list_models,
      model: nil,
      question_count: 0,
      question_ids: [],
      base_url: client.base_url,
      telemetry_metadata: opts[:telemetry_metadata] || %{}
    }

    Telemetry.request_span(metadata, fn ->
      {result, info} = Client.run(client, :get, "/v1/models", nil, opts)
      stop(decode_models(result, info), info)
    end)
  end

  @doc """
  Builds a Noul (yes/no) question. See `TypeSafe.Question.Noul`.

  ## Options

    * `:criteria` - what a yes and a no mean, as `%{true: ..., false: ...}` (either may be left out).
    * `:extra` - additional wire fields to send with the question.

  Raises `TypeSafe.Error` (type `:invalid_request`) when the question is invalid; use
  `TypeSafe.Question.Noul.new/3` for a tuple instead.

      iex> TypeSafe.noul("Is this spam?", criteria: %{true: "Unsolicited advertising"}).criteria
      %{true: "Unsolicited advertising"}
  """
  @spec noul(Question.entry(), keyword()) :: Question.Noul.t()
  def noul(instructions, opts \\ []) do
    {criteria, opts} = if Keyword.keyword?(opts), do: Keyword.pop(opts, :criteria), else: {nil, opts}
    instructions |> Question.Noul.new(criteria, opts) |> unwrap!()
  end

  @doc """
  Builds a Choice question. See `TypeSafe.Question.Choice` for the accepted criteria shapes.

  ## Options

    * `:extra` - additional wire fields to send with the question.

  Raises `TypeSafe.Error` (type `:invalid_request`) when the question is invalid; use
  `TypeSafe.Question.Choice.new/3` for a tuple instead.

  When criteria is a trailing keyword list, Elixir folds any options into it, so
  `TypeSafe.choice("Tone?", calm: nil, extra: %{})` has an option named `extra`. Wrap the
  criteria in brackets to pass options: `TypeSafe.choice("Tone?", [calm: nil], extra: %{})`.

      iex> TypeSafe.choice("Tone?", [:calm, :angry]).criteria
      [calm: nil, angry: nil]
  """
  @spec choice(Question.entry(), map() | list(), keyword()) :: Question.Choice.t()
  def choice(instructions, criteria, opts \\ []) do
    instructions |> Question.Choice.new(criteria, opts) |> unwrap!()
  end

  @doc """
  Builds a Score question from an ordered list of at least two levels. See
  `TypeSafe.Question.Score`.

  ## Options

    * `:extra` - additional wire fields to send with the question.

  Raises `TypeSafe.Error` (type `:invalid_request`) when the question is invalid; use
  `TypeSafe.Question.Score.new/3` for a tuple instead.

      iex> TypeSafe.score("Urgency?", ["Can wait", "This week", "Today"]).criteria
      ["Can wait", "This week", "Today"]
  """
  @spec score(Question.entry(), [Question.level()], keyword()) :: Question.Score.t()
  def score(instructions, criteria, opts \\ []) do
    instructions |> Question.Score.new(criteria, opts) |> unwrap!()
  end

  ## Internals

  defp do_ask(client, state, questions, model, opts) do
    case Question.build_request(state, model, questions) do
      {:ok, body, prepared} ->
        case Client.run(client, :post, "/v1/systemone", body, opts) do
          {{:ok, response}, info} ->
            result = Response.from_wire(Client.decode_body(response.body), info.request_id, prepared)
            {with_response_context(result, response, info), info}

          {{:error, error}, info} ->
            {{:error, error}, info}
        end

      {:error, error} ->
        {{:error, error}, %{status: nil, request_id: nil, retries: 0}}
    end
  end

  defp decode_models({:ok, response}, info) do
    body = Client.decode_body(response.body)

    result =
      with {:ok, %{models: models}} <- parse_models(body) do
        decode_model_list(models)
      end

    with_response_context(result, response, info)
  end

  defp decode_models({:error, error}, _info), do: {:error, error}

  defp with_response_context({:error, %Error{type: :invalid_response} = error}, response, info),
    do: {:error, Error.put_response(error, response, info.endpoint)}

  defp with_response_context(result, _response, _info), do: result

  @models_schema Zoi.map(%{models: Zoi.list(Zoi.any())}, coerce: true)

  defp parse_models(body) do
    case Zoi.parse(@models_schema, body) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, errors} -> {:error, Error.from_zoi(errors, :invalid_response, [])}
    end
  end

  defp decode_model_list(models) do
    models
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
      case TypeSafe.Model.from_wire(raw) do
        {:ok, model} ->
          {:cont, {:ok, [model | acc]}}

        {:error, errors} ->
          {:halt, {:error, Error.from_zoi(errors, :invalid_response, ["models", Integer.to_string(index)])}}
      end
    end)
    |> case do
      {:ok, models} -> {:ok, Enum.reverse(models)}
      error -> error
    end
  end

  defp stop(result, info) when is_map_key(info, :endpoint), do: stop(result, Map.delete(info, :endpoint))

  defp stop({:ok, %Response{usage: usage}} = result, info) do
    measurements =
      %{input_tokens: usage.input_tokens, output_tokens: usage.output_tokens}
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {result, measurements, Map.merge(info, %{result: :ok, error: nil})}
  end

  defp stop({:ok, _other} = result, info), do: {result, %{}, Map.merge(info, %{result: :ok, error: nil})}

  defp stop({:error, %Error{} = error} = result, info) do
    info = %{info | request_id: info.request_id || error.request_id, status: info.status || error.status}
    {result, %{}, Map.merge(info, %{result: :error, error: error})}
  end

  defp check_opts!(opts, allowed, function) do
    if !Keyword.keyword?(opts) do
      raise ArgumentError, "#{function} expects options as a keyword list, got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- allowed do
      [] ->
        Client.validate_call_opts!(opts)
        validate_opt_values!(opts, function)

      unknown ->
        raise ArgumentError, "unknown options #{inspect(unknown)} for #{function}; allowed: #{inspect(allowed)}"
    end
  end

  defp validate_opt_values!(opts, function) do
    Enum.each(opts, fn
      {:model, model} when is_binary(model) and model != "" ->
        :ok

      {:model, other} ->
        raise ArgumentError, "#{function} :model must be a non-empty string, got: #{inspect(other)}"

      {:telemetry_metadata, meta} when is_map(meta) ->
        :ok

      {:telemetry_metadata, other} ->
        raise ArgumentError, "#{function} :telemetry_metadata must be a map, got: #{inspect(other)}"

      _other ->
        :ok
    end)

    opts
  end

  defp unwrap!({:ok, question}), do: question
  defp unwrap!({:error, %Error{} = error}), do: raise(error)
end
