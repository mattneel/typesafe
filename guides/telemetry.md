# Telemetry

TypeSafe emits [`:telemetry`](https://hexdocs.pm/telemetry) events for every call to
`TypeSafe.ask/4` and `TypeSafe.list_models/2`. Use them for logs, metrics, cost tracking and
retry monitoring. The event reference lives in `TypeSafe.Telemetry`. This guide shows how to use
the events.

## Events

Each call is wrapped in one span. The span covers validation, every retry and response decoding,
so one call emits exactly one `:start` event and then one `:stop` or `:exception` event.

| Event | When | Measurements |
| --- | --- | --- |
| `[:typesafe, :request, :start]` | before validation | `:system_time`, `:monotonic_time` |
| `[:typesafe, :request, :stop]` | after the call returns, successfully or not | `:duration`, plus `:input_tokens` and `:output_tokens` when the API reported them |
| `[:typesafe, :request, :exception]` | when something raises inside the call | `:duration` |

Every event carries this metadata:

- `:operation`: `:ask` or `:list_models`.
- `:model`: the model requested, such as `"jev-latest"` (`nil` for `:list_models`).
- `:question_count` and `:question_ids`.
- `:base_url`.
- `:telemetry_metadata`: the map you passed as the `:telemetry_metadata` call option, or `%{}`.

The `:stop` event adds:

- `:result`: `:ok` or `:error`.
- `:status`: the HTTP status of the final attempt, or `nil` when no response arrived.
- `:request_id`: the `x-typesafe-request-id` of the final attempt.
- `:retries`: how many retries happened after the first attempt.
- `:error`: the `TypeSafe.Error` when `:result` is `:error`, otherwise `nil`.

`TypeSafe.ask/4` returns errors as tuples instead of raising, so a failed call ends with a `:stop`
event where `result: :error`, not with an `:exception` event. `:exception` is reserved for real
crashes, such as a custom Req step that raises.

This is the `:stop` event from a real call with three questions:

```elixir
# measurements
%{duration: 910460186, monotonic_time: -576460749239691559, input_tokens: 414, output_tokens: 73}

# metadata
%{
  operation: :ask,
  model: "jev-latest",
  question_count: 3,
  question_ids: [:department, :frustration, :is_urgent],
  base_url: "https://api.typesafe.ai",
  telemetry_metadata: %{ticket_id: 4821},
  result: :ok,
  status: 200,
  request_id: "req_01a0ac97618c76898e35b41bf6d9aa5e",
  retries: 0,
  error: nil,
  telemetry_span_context: #Reference<0.355267023.3842244635.72438>
}
```

`:model` is the model you asked for. The concrete version that answered, such as `"jev-1.13.0"`,
is on the response as `response.model`.

## Tagging calls with your own ids

Pass `:telemetry_metadata` to join events with your own records, such as a ticket or a job:

```elixir
TypeSafe.ask(client, ticket.body, questions, telemetry_metadata: %{ticket_id: ticket.id, queue: :support})
```

The map is nested under the `:telemetry_metadata` key, so it never collides with TypeSafe's own
metadata. Keep it to identifiers. The state and questions are not in the metadata, and there is
no reason to put customer text there.

## Logging

Attach a handler at application start. Use a module function rather than an anonymous function,
which `:telemetry` warns about for performance reasons:

```elixir
defmodule MyApp.TypeSafeLogger do
  require Logger

  def attach do
    :telemetry.attach("my-app-typesafe-logger", [:typesafe, :request, :stop], &__MODULE__.handle_event/4, nil)
  end

  def handle_event([:typesafe, :request, :stop], measurements, metadata, _config) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    case metadata.result do
      :ok ->
        Logger.info(
          "TypeSafe #{metadata.operation} ok in #{ms}ms " <>
            "(retries: #{metadata.retries}, request_id: #{metadata.request_id})"
        )

      :error ->
        Logger.warning(
          "TypeSafe #{metadata.operation} failed in #{ms}ms " <>
            "(retries: #{metadata.retries}): #{Exception.message(metadata.error)}"
        )
    end
  end
end
```

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  MyApp.TypeSafeLogger.attach()
  # ...
end
```

For the call above, this logs:

```text
[info] TypeSafe ask ok in 910ms (retries: 0, request_id: req_01a0ac97618c76898e35b41bf6d9aa5e)
```

This client does not read `TYPESAFE_LOG_LEVEL`, the environment variable that TypeSafe's official
Python and JavaScript SDKs use. Configure Elixir's `Logger` instead. Req logs each retry at `:debug`, for example
`retry: got response with status 529, will retry in 0ms, 2 attempts left`.

## Metrics

With [`Telemetry.Metrics`](https://hexdocs.pm/telemetry_metrics), as used by Phoenix
applications and LiveDashboard, these definitions cover latency, errors, token usage and retries:

```elixir
import Telemetry.Metrics

[
  summary("typesafe.request.stop.duration",
    unit: {:native, :millisecond},
    tags: [:operation, :model, :result]
  ),
  counter("typesafe.request.stop.duration",
    tags: [:result, :error_type],
    tag_values: fn metadata -> Map.put(metadata, :error_type, metadata.error && metadata.error.type) end
  ),
  sum("typesafe.request.stop.input_tokens", tags: [:model], keep: &(&1.result == :ok)),
  sum("typesafe.request.stop.output_tokens", tags: [:model], keep: &(&1.result == :ok)),
  distribution("typesafe.request.stop.retries",
    measurement: fn _measurements, metadata -> metadata.retries end,
    reporter_options: [buckets: [0, 1, 2]]
  )
]
```

- The token sums keep only successful calls, because failed calls report no usage.
- `:retries` is metadata, so the last metric reads it with a `:measurement` function.
- Tag by `:error_type` rather than by the whole error, to keep the number of tag values small.

## Watching retries

The `:retries` count is the main signal for rate limiting and overload. Calls that succeed after
retries return `{:ok, response}`, so nothing in the result shows the pressure. The events do. A
rising share of calls with `retries > 0`, or retried calls with long durations, means you are
close to the limit. Lower your concurrency before calls start failing with `:rate_limited` or
`:overloaded`. See [Batching and concurrency](batching.md).

## Per-attempt and connection events

TypeSafe's span is per call. For per-attempt detail, Finch emits its own events, including
`[:finch, :request, :stop]` for each HTTP request, `[:finch, :queue, :stop]` for time spent
waiting for a pooled HTTP/1 connection, and `[:finch, :connect, :stop]` for new connections. See
`Finch.Telemetry`.

Requests made through `TypeSafe.Req.attach/2` do not emit `[:typesafe, :request, ...]` events.
Your Req pipeline owns those calls. The Finch events still apply.

## Spans for your own workflow

`TypeSafe.Telemetry.span/3` wraps a function in a span, like `:telemetry.span/3`, but merges the
stop metadata over the start metadata. You can use it to measure a whole decision, including the
TypeSafe call and your routing logic, under your own event name:

```elixir
TypeSafe.Telemetry.span([:my_app, :triage], %{ticket_id: ticket.id}, fn ->
  {:ok, decision} = MyApp.Support.Router.route(ticket.body)
  {decision, %{decision: elem(decision, 0)}}
end)
```

This emits `[:my_app, :triage, :start]` and `[:my_app, :triage, :stop]`. The `:stop` metadata
includes both `ticket_id` and `decision`.

## Testing

See [Testing telemetry](testing.md#testing-telemetry) for asserting on events with
`:telemetry_test`.
