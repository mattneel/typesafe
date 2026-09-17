if Code.ensure_loaded?(Plug.Conn) do
  defmodule TypeSafe.Test do
    @moduledoc """
    Test helpers for applications that call TypeSafe, built on `Req.Test`.

    The helpers install `Req.Test` stubs that answer the way the API does, so your tests run
    without the network and with `async: true`. They are compiled only when `Plug` is available,
    which `Req.Test` needs anyway.

    ## Setup

    Route the client through `Req.Test` in `config/test.exs`, and turn off retries so an error
    stub fails fast:

        config :typesafe,
          api_key: "test",
          retry: false,
          req_options: [plug: {Req.Test, TypeSafe}]

    ## Stubbing answers

        test "routes urgent billing tickets" do
          TypeSafe.Test.stub_answers(%{
            department: {:choice, :technical, %{billing: 0.08, technical: 0.85, sales: 0.07}, 0.82},
            is_urgent: {:noul, 0.92},
            frustration: {:score, 1.6, ["Calm", "Frustrated", "Very angry"], %{0 => 0.05, 1 => 0.3, 2 => 0.65}, 0.78}
          })

          assert {:ok, %TypeSafe.Response{answers: %{department: %{choice: :technical}}}} =
                   MyApp.Router.route(ticket)
        end

    Each answer is one of:

      * `{:noul, probability}`
      * `{:choice, choice, probabilities}` or `{:choice, choice, probabilities, confidence}`
      * `{:score, score, legend, probabilities}` or `{:score, score, legend, probabilities, confidence}`,
        where `legend` is a list of levels or a map of level index to level
      * a `TypeSafe.Answer.Noul`, `TypeSafe.Answer.Choice` or `TypeSafe.Answer.Score` struct

    When `confidence` is omitted, the top probability is used as a placeholder. TypeSafe does
    not publish how confidence is derived, so a test that thresholds on confidence should set it
    explicitly.

    The stub checks that the question ids your code sends match the stubbed ids exactly, and that
    each question's type matches its stubbed answer. A renamed or retyped question fails the
    test with a clear message instead of silently returning nothing.

    ## Processes

    Stubs follow `Req.Test`'s ownership model. When the call happens in another process, such as
    a `Task` started outside your test process or a GenServer, allow it:

        Req.Test.allow(TypeSafe, self(), pid)

    ## Composing with `Req.Test.expect/3`

    `answers_plug/2`, `error_plug/2` and `models_plug/2` return the plugs the `stub_*` functions
    install, so you can script a sequence of responses:

        Req.Test.expect(TypeSafe, TypeSafe.Test.error_plug(529))
        Req.Test.expect(TypeSafe, TypeSafe.Test.answers_plug(%{is_urgent: {:noul, 0.9}}))
    """

    alias Plug.Conn.Status
    alias TypeSafe.Answer
    alias TypeSafe.Question.Choice

    @default_name TypeSafe
    @default_model "jev-latest"

    @typedoc "A stubbed answer. See the module documentation."
    @type answer_spec ::
            {:noul, number()}
            | {:choice, Choice.option(), map()}
            | {:choice, Choice.option(), map(), number()}
            | {:score, number(), list() | map(), map()}
            | {:score, number(), list() | map(), map(), number()}
            | Answer.t()

    @doc """
    Stubs `POST /v1/systemone` to return the given answers.

    `answers` is a map or keyword list of question id to answer spec.

    ## Options

      * `:name` - the `Req.Test` stub name, default `TypeSafe`.
      * `:model` - the model reported in the response, default `"jev-latest"`.
      * `:usage` - a map with `:input_tokens` and `:output_tokens`, default 0 each.
      * `:request_id` - the `x-typesafe-request-id` header, default a generated `"req_test_..."`.

    ## Example

        iex> TypeSafe.Test.stub_answers(%{is_urgent: {:noul, 0.92}}, model: "jev-1.13.0")
        :ok
        iex> client = TypeSafe.new(api_key: "ts_test_key", retry: false, req_options: [plug: {Req.Test, TypeSafe}])
        iex> {:ok, response} = TypeSafe.ask(client, "Payouts failing!", %{is_urgent: TypeSafe.noul("Is this urgent?")})
        iex> {response.answers.is_urgent.noul, response.model}
        {0.92, "jev-1.13.0"}
    """
    @spec stub_answers(map() | keyword(), keyword()) :: :ok
    def stub_answers(answers, opts \\ []) do
      Req.Test.stub(Keyword.get(opts, :name, @default_name), answers_plug(answers, opts))
    end

    @doc """
    Returns a plug that answers `POST /v1/systemone` with the given answers.

    Accepts the same arguments and options as `stub_answers/2` (`:name` is ignored).

    ## Example

        iex> Req.Test.expect(TypeSafe, TypeSafe.Test.error_plug(503))
        iex> Req.Test.expect(TypeSafe, TypeSafe.Test.answers_plug(%{spam: {:noul, 0.05}}))
        iex> client = TypeSafe.new(api_key: "ts_test_key", retry: false, req_options: [plug: {Req.Test, TypeSafe}])
        iex> questions = %{spam: TypeSafe.noul("Is this spam?")}
        iex> {:error, %TypeSafe.Error{type: :server}} = TypeSafe.ask(client, "Hello", questions)
        iex> {:ok, response} = TypeSafe.ask(client, "Hello", questions)
        iex> response.answers.spam.noul
        0.05
    """
    @spec answers_plug(map() | keyword(), keyword()) :: (Plug.Conn.t() -> Plug.Conn.t())
    def answers_plug(answers, opts \\ []) do
      stubbed = normalize_answers(answers)
      model = Keyword.get(opts, :model, @default_model)
      usage = Keyword.get(opts, :usage, %{input_tokens: 0, output_tokens: 0})
      request_id = Keyword.get(opts, :request_id)

      fn conn ->
        questions = systemone_questions!(conn)
        check_ids!(questions, stubbed)
        check_types!(questions, stubbed)

        body = %{
          "model" => model,
          "answers" => Map.new(stubbed, fn {id, {_type, wire}} -> {id, wire} end),
          "usage" => %{
            "input_tokens" => Map.get(usage, :input_tokens, 0),
            "output_tokens" => Map.get(usage, :output_tokens, 0)
          }
        }

        send_json(conn, 200, body, request_id: request_id)
      end
    end

    @doc """
    Stubs every TypeSafe request to fail with an HTTP `status`.

    ## Options

      * `:body` - the error body, a map or a string. Defaults to `%{"detail" => reason}`.
      * `:headers` - extra response headers, as a map or list of `{name, value}`.
      * `:retry_after_ms` - sets both `retry-after-ms` and `Retry-After` (rounded up to seconds).
      * `:request_id` - the `x-typesafe-request-id` header, default a generated `"req_test_..."`.
      * `:name` - the `Req.Test` stub name, default `TypeSafe`.

    ## Examples

        TypeSafe.Test.stub_error(429, retry_after_ms: 1200)
        assert {:error, %TypeSafe.Error{type: :rate_limited, retry_after_ms: 1200}} = MyApp.classify(text)

    Against a client:

        iex> TypeSafe.Test.stub_error(429, retry_after_ms: 1_200)
        :ok
        iex> client = TypeSafe.new(api_key: "ts_test_key", retry: false, req_options: [plug: {Req.Test, TypeSafe}])
        iex> {:error, error} = TypeSafe.ask(client, "state", %{spam: TypeSafe.noul("Is this spam?")})
        iex> {error.type, error.status, error.retry_after_ms, error.message}
        {:rate_limited, 429, 1200, "Too Many Requests"}
    """
    @spec stub_error(pos_integer(), keyword()) :: :ok
    def stub_error(status, opts \\ []) do
      Req.Test.stub(Keyword.get(opts, :name, @default_name), error_plug(status, opts))
    end

    @doc """
    Returns a plug that fails with an HTTP `status`. Accepts the options of `stub_error/2`.

    ## Example

        iex> Req.Test.expect(TypeSafe, TypeSafe.Test.error_plug(529))
        iex> client = TypeSafe.new(api_key: "ts_test_key", retry: false, req_options: [plug: {Req.Test, TypeSafe}])
        iex> {:error, error} = TypeSafe.ask(client, "state", %{spam: TypeSafe.noul("Is this spam?")})
        iex> {error.type, error.status, error.message}
        {:overloaded, 529, "Overloaded"}
    """
    @spec error_plug(pos_integer(), keyword()) :: (Plug.Conn.t() -> Plug.Conn.t())
    def error_plug(status, opts \\ []) when is_integer(status) and status in 100..599 do
      body = Keyword.get_lazy(opts, :body, fn -> %{"detail" => reason_phrase(status)} end)

      headers =
        opts
        |> Keyword.get(:headers, [])
        |> Enum.map(fn {name, value} -> {name |> to_string() |> String.downcase(), to_string(value)} end)

      headers =
        case Keyword.get(opts, :retry_after_ms) do
          nil -> headers
          ms -> headers ++ [{"retry-after-ms", to_string(ms)}, {"retry-after", to_string(ceil(ms / 1000))}]
        end

      request_id = Keyword.get(opts, :request_id)

      fn conn ->
        conn = Enum.reduce(headers, conn, fn {name, value}, conn -> Plug.Conn.put_resp_header(conn, name, value) end)

        case body do
          binary when is_binary(binary) ->
            conn
            |> put_request_id(request_id)
            |> Plug.Conn.put_resp_content_type("text/plain")
            |> Plug.Conn.send_resp(status, binary)

          term ->
            send_json(conn, status, term, request_id: request_id)
        end
      end
    end

    @doc """
    Stubs every TypeSafe request to fail with a transport error, such as `:timeout`,
    `:econnrefused` or `:closed`.

    ## Options

      * `:name` - the `Req.Test` stub name, default `TypeSafe`.

    ## Example

        iex> TypeSafe.Test.stub_transport_error(:econnrefused)
        :ok
        iex> client = TypeSafe.new(api_key: "ts_test_key", retry: false, req_options: [plug: {Req.Test, TypeSafe}])
        iex> {:error, error} = TypeSafe.list_models(client)
        iex> {error.type, error.reason}
        {:transport, :econnrefused}
    """
    @spec stub_transport_error(atom(), keyword()) :: :ok
    def stub_transport_error(reason, opts \\ []) when is_atom(reason) do
      Req.Test.stub(Keyword.get(opts, :name, @default_name), &Req.Test.transport_error(&1, reason))
    end

    @doc """
    Stubs `GET /v1/models` to return the given models.

    Each model is a `TypeSafe.Model` struct or a map with `:name`, `:description` and
    `:release_date`. Accepts the `:name` and `:request_id` options.

    ## Example

        iex> TypeSafe.Test.stub_models([%{name: "jev-latest"}, %{name: "jev-preview"}])
        :ok
        iex> client = TypeSafe.new(api_key: "ts_test_key", retry: false, req_options: [plug: {Req.Test, TypeSafe}])
        iex> {:ok, models} = TypeSafe.list_models(client)
        iex> Enum.map(models, & &1.name)
        ["jev-latest", "jev-preview"]
    """
    @spec stub_models([TypeSafe.Model.t() | map()], keyword()) :: :ok
    def stub_models(models, opts \\ []) do
      Req.Test.stub(Keyword.get(opts, :name, @default_name), models_plug(models, opts))
    end

    @doc """
    Returns a plug that answers `GET /v1/models`. Accepts the options of `stub_models/2`.

    ## Example

        iex> Req.Test.expect(TypeSafe, &Req.Test.transport_error(&1, :closed))
        iex> Req.Test.expect(TypeSafe, TypeSafe.Test.models_plug([%{name: "jev-latest"}]))
        iex> client = TypeSafe.new(api_key: "ts_test_key", retry: false, req_options: [plug: {Req.Test, TypeSafe}])
        iex> {:error, %TypeSafe.Error{type: :transport, reason: :closed}} = TypeSafe.list_models(client)
        iex> {:ok, [model]} = TypeSafe.list_models(client)
        iex> model.name
        "jev-latest"
    """
    @spec models_plug([TypeSafe.Model.t() | map()], keyword()) :: (Plug.Conn.t() -> Plug.Conn.t())
    def models_plug(models, opts \\ []) when is_list(models) do
      wire = Enum.map(models, &model_wire/1)

      request_id = Keyword.get(opts, :request_id)

      fn conn ->
        if !(conn.method == "GET" and String.ends_with?(conn.request_path, "/v1/models")) do
          fail!("TypeSafe.Test models stub expected GET /v1/models, got #{conn.method} #{conn.request_path}")
        end

        send_json(conn, 200, %{"models" => wire}, request_id: request_id)
      end
    end

    ## Internals

    defp systemone_questions!(conn) do
      if !(conn.method == "POST" and String.ends_with?(conn.request_path, "/v1/systemone")) do
        fail!(
          "TypeSafe.Test answers stub expected POST /v1/systemone, got #{conn.method} #{conn.request_path}. " <>
            "Use TypeSafe.Test.stub_models/2 for list_models."
        )
      end

      with raw when raw != "" <- conn |> Req.Test.raw_body() |> IO.iodata_to_binary(),
           {:ok, %{"questions" => %{} = questions}} <- JSON.decode(raw) do
        questions
      else
        _ -> fail!("TypeSafe.Test answers stub received a request without a JSON \"questions\" object")
      end
    end

    defp check_ids!(questions, stubbed) do
      sent = questions |> Map.keys() |> MapSet.new()
      expected = stubbed |> Map.keys() |> MapSet.new()

      if sent != expected do
        missing = expected |> MapSet.difference(sent) |> Enum.sort()
        unexpected = sent |> MapSet.difference(expected) |> Enum.sort()

        fail!("""
        TypeSafe.Test: the question ids sent do not match the stubbed answers.

          sent but not stubbed: #{inspect(unexpected)}
          stubbed but not sent: #{inspect(missing)}
        """)
      end
    end

    defp check_types!(questions, stubbed) do
      Enum.each(stubbed, fn {id, {type, _wire}} ->
        sent_type = get_in(questions, [id, "type"])

        if sent_type != type do
          fail!(
            "TypeSafe.Test: question #{inspect(id)} was sent as #{inspect(sent_type)} but stubbed as #{inspect(type)}"
          )
        end
      end)
    end

    defp normalize_answers(answers) when is_map(answers) or is_list(answers) do
      Map.new(answers, fn
        {id, spec} when is_atom(id) or is_binary(id) -> {to_string(id), answer_wire(id, spec)}
        other -> raise ArgumentError, "expected {question_id, answer} pairs, got: #{inspect(other)}"
      end)
    end

    defp answer_wire(_id, {:noul, p}) when is_number(p), do: {"noul", %{"type" => "noul", "noul" => p}}
    defp answer_wire(_id, %Answer.Noul{noul: p}), do: {"noul", %{"type" => "noul", "noul" => p}}

    defp answer_wire(id, {:choice, choice, probabilities}), do: answer_wire(id, {:choice, choice, probabilities, nil})

    defp answer_wire(_id, {:choice, choice, probabilities, confidence}) when is_map(probabilities) do
      probabilities = Map.new(probabilities, fn {option, p} -> {to_string(option), p} end)

      {"choice",
       %{
         "type" => "choice",
         "choice" => to_string(choice),
         "probabilities" => probabilities,
         "confidence" => confidence || top(probabilities)
       }}
    end

    defp answer_wire(id, %Answer.Choice{} = answer),
      do: answer_wire(id, {:choice, answer.choice, answer.probabilities, answer.confidence})

    defp answer_wire(id, {:score, score, legend, probabilities}),
      do: answer_wire(id, {:score, score, legend, probabilities, nil})

    defp answer_wire(_id, {:score, score, legend, probabilities, confidence})
         when is_number(score) and (is_list(legend) or is_map(legend)) and is_map(probabilities) do
      legend =
        if is_list(legend),
          do: legend |> Enum.with_index() |> Map.new(fn {level, index} -> {Integer.to_string(index), level} end),
          else: Map.new(legend, fn {index, level} -> {to_string(index), level} end)

      probabilities = Map.new(probabilities, fn {index, p} -> {to_string(index), p} end)

      {"score",
       %{
         "type" => "score",
         "score" => score,
         "legend" => legend,
         "probabilities" => probabilities,
         "confidence" => confidence || top(probabilities)
       }}
    end

    defp answer_wire(id, %Answer.Score{} = answer),
      do: answer_wire(id, {:score, answer.score, answer.legend, answer.probabilities, answer.confidence})

    defp answer_wire(id, spec) do
      raise ArgumentError, """
      invalid stubbed answer for #{inspect(id)}: #{inspect(spec)}

      Expected {:noul, p}, {:choice, choice, probabilities[, confidence]},
      {:score, score, legend, probabilities[, confidence]} or a TypeSafe.Answer struct.
      """
    end

    defp top(probabilities) when map_size(probabilities) == 0, do: 0.0
    defp top(probabilities), do: probabilities |> Map.values() |> Enum.max()

    defp send_json(conn, status, body, opts) do
      conn
      |> put_request_id(Keyword.get(opts, :request_id))
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, JSON.encode!(body))
    end

    defp put_request_id(conn, request_id) do
      Plug.Conn.put_resp_header(conn, "x-typesafe-request-id", request_id || generate_request_id())
    end

    defp generate_request_id do
      "req_test_#{System.unique_integer([:positive, :monotonic])}"
    end

    defp model_wire(%TypeSafe.Model{} = model), do: model |> Map.from_struct() |> model_wire()

    defp model_wire(%{} = model) do
      model = Map.new(model, fn {key, value} -> {to_string(key), value} end)

      %{
        "name" => model["name"] || raise(ArgumentError, "stubbed model is missing :name: #{inspect(model)}"),
        "description" => model["description"] || "",
        "release_date" => model["release_date"] || "2026-01-01"
      }
    end

    defp reason_phrase(529), do: "Overloaded"

    defp reason_phrase(status) do
      Status.reason_phrase(status)
    rescue
      ArgumentError -> "HTTP #{status}"
    end

    @spec fail!(String.t()) :: no_return()
    defp fail!(message) do
      if Code.ensure_loaded?(ExUnit.AssertionError) do
        raise ExUnit.AssertionError, message: message
      else
        raise message
      end
    end
  end
end
