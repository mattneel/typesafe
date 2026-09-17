defmodule TypeSafe.TelemetryTest do
  # Telemetry handlers are global, so every test tags its calls with a unique id (or base URL)
  # and only matches events carrying it. That keeps the module safe to run async.
  use ExUnit.Case, async: true

  import TypeSafe.TestHelpers, only: [client: 0, client: 1]
  import TypeSafe.TransportHelpers

  alias TypeSafe.Error
  alias TypeSafe.Telemetry

  @moduletag :capture_log

  @start [:typesafe, :request, :start]
  @stop [:typesafe, :request, :stop]
  @exception [:typesafe, :request, :exception]

  setup do
    ref = :telemetry_test.attach_event_handlers(self(), Telemetry.events())
    on_exit(fn -> :telemetry.detach(ref) end)

    id = System.unique_integer([:positive])
    %{ref: ref, id: id, meta: [telemetry_metadata: %{test_id: id}]}
  end

  describe "ask/4" do
    test "a successful call emits one start and one stop with the documented data", ctx do
      Req.Test.stub(TypeSafe, &json(&1, 200, systemone_body()))

      assert {:ok, _response} = TypeSafe.ask(client(), "state", questions(), ctx.meta)

      {start_measurements, start_metadata} = assert_event(ctx, @start)
      assert %{system_time: system_time, monotonic_time: monotonic_time} = start_measurements
      assert is_integer(system_time) and is_integer(monotonic_time)

      assert Map.delete(start_metadata, :telemetry_span_context) == %{
               operation: :ask,
               model: "jev-latest",
               question_count: 3,
               question_ids: [:department, :frustration, :is_urgent],
               base_url: "https://api.typesafe.ai",
               telemetry_metadata: %{test_id: ctx.id}
             }

      {stop_measurements, stop_metadata} = assert_event(ctx, @stop)
      assert %{duration: duration, input_tokens: 414, output_tokens: 73} = stop_measurements
      assert measurement_keys(stop_measurements) == [:duration, :input_tokens, :output_tokens]
      assert is_integer(duration) and duration >= 0

      assert stop_metadata ==
               Map.merge(start_metadata, %{result: :ok, status: 200, request_id: request_id(), retries: 0, error: nil})

      assert_no_more_events(ctx)
    end

    test "metadata reflects the per-call model and the order of a keyword list", ctx do
      Req.Test.stub(TypeSafe, &json(&1, 200, noul_body("b")))
      questions = [b: TypeSafe.noul("B?")]

      assert {:ok, _response} = TypeSafe.ask(client(), "state", questions, [model: "jev-preview"] ++ ctx.meta)

      {_measurements, metadata} = assert_event(ctx, @start)
      assert %{model: "jev-preview", question_ids: [:b], question_count: 1} = metadata
      assert_event(ctx, @stop)
    end

    test "token measurements are present only when usage is reported", ctx do
      body = Map.delete(noul_body(), "usage")
      Req.Test.stub(TypeSafe, &json(&1, 200, body))

      assert {:ok, _response} = TypeSafe.ask(client(), "state", noul_question(), ctx.meta)
      {measurements, _metadata} = assert_event(ctx, @stop)
      assert measurement_keys(measurements) == [:duration]

      Req.Test.stub(TypeSafe, &json(&1, 200, Map.put(body, "usage", %{"input_tokens" => 9})))

      assert {:ok, _response} = TypeSafe.ask(client(), "state", noul_question(), ctx.meta)
      {measurements, _metadata} = assert_event(ctx, @stop)
      assert measurement_keys(measurements) == [:duration, :input_tokens]
      assert measurements.input_tokens == 9
    end

    test "an API error emits a stop with result :error and the error", ctx do
      Req.Test.stub(TypeSafe, &json(&1, 401, %{"detail" => %{"message" => "Cannot authenticate."}}))

      assert {:error, error} = TypeSafe.ask(client(), "state", noul_question(), ctx.meta)

      assert_event(ctx, @start)
      {measurements, metadata} = assert_event(ctx, @stop)
      assert measurement_keys(measurements) == [:duration]
      assert %{result: :error, status: 401, request_id: "req_01a0ac5f3b2e4d6c8a9b", retries: 0} = metadata
      assert %Error{type: :authentication} = metadata.error
      assert metadata.error == error
      assert_no_more_events(ctx)
    end

    test "an invalid response emits a stop with the 2xx status and the error", ctx do
      Req.Test.stub(TypeSafe, &json(&1, 200, %{"model" => "jev-1.13.0"}))

      assert {:error, %Error{type: :invalid_response}} = TypeSafe.ask(client(), "state", noul_question(), ctx.meta)

      {_measurements, metadata} = assert_event(ctx, @stop)
      assert %{result: :error, status: 200, request_id: "req_01a0ac5f3b2e4d6c8a9b", retries: 0} = metadata
      assert %Error{type: :invalid_response, status: 200} = metadata.error
      refute Map.has_key?(metadata, :endpoint)
    end

    test "an invalid request emits start and stop without a status", ctx do
      refute_network()

      assert {:error, %Error{type: :invalid_request}} = TypeSafe.ask(client(), "state", %{}, ctx.meta)

      {_measurements, start_metadata} = assert_event(ctx, @start)
      assert %{question_count: 0, question_ids: []} = start_metadata

      {_measurements, metadata} = assert_event(ctx, @stop)
      assert %{result: :error, status: nil, request_id: nil, retries: 0} = metadata
      assert %Error{type: :invalid_request, path: ["questions"]} = metadata.error
      assert_no_more_events(ctx)
    end

    test "question ids are reported even when the questions are invalid", ctx do
      refute_network()

      assert {:error, %Error{type: :invalid_request}} =
               TypeSafe.ask(client(), "state", %{a: "not a question", b: TypeSafe.noul("B?")}, ctx.meta)

      assert {:error, %Error{type: :invalid_request}} = TypeSafe.ask(client(), "state", "not questions", ctx.meta)

      assert {_measurements, %{question_count: 2, question_ids: [:a, :b]}} = assert_event(ctx, @start)
      assert {_measurements, %{question_count: 0, question_ids: []}} = assert_event(ctx, @start)
    end

    test "a retried success reports the retries and the final status in one span", ctx do
      Req.Test.expect(TypeSafe, &json(&1, 503, %{"detail" => "Service Unavailable"}))
      Req.Test.expect(TypeSafe, &json(&1, 429, %{"detail" => "Too Many Requests"}, [{"retry-after-ms", "50"}]))
      Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))

      assert {:ok, _response} = TypeSafe.ask(client(), "state", noul_question(), ctx.meta)

      assert_event(ctx, @start)
      {measurements, metadata} = assert_event(ctx, @stop)
      assert %{result: :ok, status: 200, retries: 2, error: nil} = metadata
      assert System.convert_time_unit(measurements.duration, :native, :millisecond) >= 50
      assert_no_more_events(ctx)
    end

    test "a failure after retries reports the final attempt", ctx do
      Req.Test.expect(TypeSafe, 2, &json(&1, 503, %{"detail" => "Service Unavailable"}))
      Req.Test.expect(TypeSafe, &json(&1, 500, %{"detail" => "boom"}, [{"x-typesafe-request-id", "req_final"}]))

      assert {:error, %Error{status: 500}} = TypeSafe.ask(client(), "state", noul_question(), ctx.meta)

      {_measurements, metadata} = assert_event(ctx, @stop)
      assert %{result: :error, status: 500, request_id: "req_final", retries: 2} = metadata
    end

    test "transport errors report retries without a status", ctx do
      Req.Test.stub(TypeSafe, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Error{type: :transport}} = TypeSafe.ask(client(), "state", noul_question(), ctx.meta)
      {_measurements, metadata} = assert_event(ctx, @stop)
      assert %{result: :error, status: nil, request_id: nil, retries: 2} = metadata

      assert {:error, %Error{type: :transport}} =
               TypeSafe.ask(client(), "state", noul_question(), [retry: false] ++ ctx.meta)

      assert {_measurements, %{retries: 0}} = assert_event(ctx, @stop)
    end

    test "telemetry_metadata defaults to an empty map", ctx do
      base_url = "https://telemetry-#{ctx.id}.example.com"
      Req.Test.stub(TypeSafe, &json(&1, 200, noul_body()))

      assert {:ok, _response} = TypeSafe.ask(client(base_url: base_url), "state", noul_question())

      assert_received {@start, _ref, _measurements, %{base_url: ^base_url, telemetry_metadata: metadata}}
      assert metadata == %{}
      assert_received {@stop, _ref, _measurements, %{base_url: ^base_url, result: :ok}}
    end

    test "a raising plug emits an exception event instead of a stop", ctx do
      Req.Test.stub(TypeSafe, fn _conn -> raise "plug exploded" end)

      assert_raise RuntimeError, "plug exploded", fn ->
        TypeSafe.ask(client(), "state", noul_question(), ctx.meta)
      end

      {_measurements, start_metadata} = assert_event(ctx, @start)
      {measurements, metadata} = assert_event(ctx, @exception)

      assert measurement_keys(measurements) == [:duration]
      assert %{kind: :error, reason: %RuntimeError{message: "plug exploded"}, stacktrace: [_ | _]} = metadata
      assert Map.drop(metadata, [:kind, :reason, :stacktrace]) == start_metadata
      assert_no_more_events(ctx)
    end

    test "a crashing custom Req step emits an exception event", ctx do
      refute_network()
      client = client()
      step = fn _request -> raise ArgumentError, "tracing step crashed" end
      client = %{client | req: Req.Request.prepend_request_steps(client.req, tracing: step)}

      assert_raise ArgumentError, "tracing step crashed", fn ->
        TypeSafe.ask(client, "state", noul_question(), ctx.meta)
      end

      assert_event(ctx, @start)
      assert {_measurements, %{kind: :error, reason: %ArgumentError{}}} = assert_event(ctx, @exception)
      assert_no_more_events(ctx)
    end
  end

  describe "list_models/2" do
    test "emits a span with operation :list_models and no questions", ctx do
      Req.Test.stub(TypeSafe, &json(&1, 200, models_body()))

      assert {:ok, [_, _]} = TypeSafe.list_models(client(), ctx.meta)

      {_measurements, start_metadata} = assert_event(ctx, @start)

      assert Map.delete(start_metadata, :telemetry_span_context) == %{
               operation: :list_models,
               model: nil,
               question_count: 0,
               question_ids: [],
               base_url: "https://api.typesafe.ai",
               telemetry_metadata: %{test_id: ctx.id}
             }

      {measurements, metadata} = assert_event(ctx, @stop)
      assert measurement_keys(measurements) == [:duration]
      assert %{result: :ok, status: 200, request_id: "req_01a0ac5f3b2e4d6c8a9b", retries: 0, error: nil} = metadata
      assert_no_more_events(ctx)
    end

    test "reports errors and retries", ctx do
      Req.Test.expect(TypeSafe, &json(&1, 529, %{"detail" => "Overloaded"}))
      Req.Test.expect(TypeSafe, &json(&1, 404, %{"detail" => "Not Found"}))

      assert {:error, %Error{type: :not_found}} = TypeSafe.list_models(client(), ctx.meta)

      {_measurements, metadata} = assert_event(ctx, @stop)
      assert %{operation: :list_models, result: :error, status: 404, retries: 1} = metadata
      assert %Error{type: :not_found} = metadata.error
    end
  end

  describe "span/3" do
    setup do
      events = [[:typesafe_telemetry_test, :span, :start], [:typesafe_telemetry_test, :span, :stop]]
      ref = :telemetry_test.attach_event_handlers(self(), events ++ [[:typesafe_telemetry_test, :span, :exception]])
      on_exit(fn -> :telemetry.detach(ref) end)
      %{span_ref: ref}
    end

    test "merges the stop metadata over the start metadata", %{span_ref: ref, id: id} do
      assert Telemetry.span([:typesafe_telemetry_test, :span], %{id: id, a: 1, b: 2}, fn -> {:done, %{b: 3, c: 4}} end) ==
               :done

      assert_received {[:typesafe_telemetry_test, :span, :start], ^ref, _measurements, %{id: ^id, a: 1, b: 2}}
      assert_received {[:typesafe_telemetry_test, :span, :stop], ^ref, measurements, %{id: ^id} = metadata}
      assert %{a: 1, b: 3, c: 4} = metadata
      assert measurement_keys(measurements) == [:duration]
    end

    test "adds extra measurements from a three-element result", %{span_ref: ref, id: id} do
      assert Telemetry.span([:typesafe_telemetry_test, :span], %{id: id}, fn -> {:done, %{tokens: 5}, %{ok: true}} end) ==
               :done

      assert_received {[:typesafe_telemetry_test, :span, :stop], ^ref, %{duration: _, tokens: 5}, %{id: ^id, ok: true}}
    end

    test "emits an exception event with the start metadata and re-raises", %{span_ref: ref, id: id} do
      assert_raise RuntimeError, "span failed", fn ->
        Telemetry.span([:typesafe_telemetry_test, :span], %{id: id}, fn -> raise "span failed" end)
      end

      assert_received {[:typesafe_telemetry_test, :span, :exception], ^ref, %{duration: _},
                       %{id: ^id, kind: :error, reason: %RuntimeError{}}}

      refute_received {[:typesafe_telemetry_test, :span, :stop], ^ref, _measurements, %{id: ^id}}
    end
  end

  test "events/0 lists the start, stop and exception events" do
    assert Telemetry.events() == [@start, @stop, @exception]
  end

  defp assert_event(%{ref: ref, id: id}, event) do
    assert_received {^event, ^ref, measurements, %{telemetry_metadata: %{test_id: ^id}} = metadata}
    {measurements, metadata}
  end

  # `:telemetry.span/3` adds its own `:monotonic_time`; the SDK documents the rest.
  defp measurement_keys(measurements), do: measurements |> Map.delete(:monotonic_time) |> Map.keys() |> Enum.sort()

  defp assert_no_more_events(%{ref: ref, id: id}) do
    for event <- [@start, @stop, @exception] do
      refute_received {^event, ^ref, _measurements, %{telemetry_metadata: %{test_id: ^id}}}
    end
  end
end
