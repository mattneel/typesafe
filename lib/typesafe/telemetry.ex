defmodule TypeSafe.Telemetry do
  @moduledoc ~S"""
  Telemetry events emitted by TypeSafe.

  Each call to `TypeSafe.ask/4` or `TypeSafe.list_models/2` is wrapped in one
  `:telemetry.span/3`. The span covers the whole call, including validation, every retry and
  response decoding, so one call emits exactly one `:start` and one `:stop` (or `:exception`).

  Finch already emits per-attempt events (`[:finch, ...]`), so TypeSafe does not duplicate
  them.

  ## `[:typesafe, :request, :start]`

  Measurements: `:system_time`, `:monotonic_time`.

  Metadata (`:telemetry.span/3` also adds `:telemetry_span_context` to every event):

    * `:operation` - `:ask` or `:list_models`.
    * `:model` - the model requested (`nil` for `:list_models`).
    * `:question_count` - the number of questions.
    * `:question_ids` - the question ids, as given.
    * `:base_url` - the API base URL.
    * `:telemetry_metadata` - the map passed as the `:telemetry_metadata` call option (`%{}`
      when none).

  ## `[:typesafe, :request, :stop]`

  Measurements:

    * `:duration` - the call's duration in `:native` time units.
    * `:monotonic_time` - added by `:telemetry.span/3`.
    * `:input_tokens`, `:output_tokens` - token usage, present only when the API reported it.

  Metadata: everything from `:start`, plus:

    * `:result` - `:ok` or `:error`.
    * `:status` - the HTTP status of the final attempt, or `nil` when no response arrived.
    * `:request_id` - the `x-typesafe-request-id` header of the final attempt, when present.
    * `:retries` - how many retries happened after the first attempt.
    * `:error` - the `TypeSafe.Error` when `:result` is `:error`, otherwise `nil`.

  A `:stop` event with `result: :error` is how failed calls are reported, because TypeSafe
  returns errors as tuples rather than raising.

  ## `[:typesafe, :request, :exception]`

  Emitted only when something raises inside the span, such as a crashing custom Req step.

  Measurements: `:duration`. Metadata: everything from `:start`, plus `:kind`, `:reason` and
  `:stacktrace`.

  ## Example

      :telemetry.attach(
        "log-typesafe-calls",
        [:typesafe, :request, :stop],
        fn _event, measurements, metadata, _config ->
          ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

          Logger.info(
            "TypeSafe #{metadata.operation} #{metadata.result} in #{ms}ms " <>
              "(retries: #{metadata.retries}, request_id: #{metadata.request_id})"
          )
        end,
        nil
      )
  """

  @prefix [:typesafe, :request]

  @doc """
  Returns the names of every event TypeSafe emits.

      iex> TypeSafe.Telemetry.events()
      [[:typesafe, :request, :start], [:typesafe, :request, :stop], [:typesafe, :request, :exception]]
  """
  @spec events() :: [[atom()]]
  def events, do: [@prefix ++ [:start], @prefix ++ [:stop], @prefix ++ [:exception]]

  @doc """
  Runs `fun` inside a telemetry span named `event_prefix`.

  Behaves like `:telemetry.span/3`, except that the metadata `fun` returns is merged over the
  start metadata instead of replacing it. `fun` returns `{result, stop_metadata}` or
  `{result, extra_measurements, stop_metadata}`.

      iex> TypeSafe.Telemetry.span([:my_app, :judge], %{step: 1}, fn -> {:done, %{outcome: :ok}} end)
      :done
  """
  @spec span([atom()], map(), (-> {result, map()} | {result, map(), map()})) :: result when result: term()
  def span(event_prefix, start_metadata, fun) when is_list(event_prefix) and is_map(start_metadata) do
    :telemetry.span(event_prefix, start_metadata, fn ->
      case fun.() do
        {result, measurements, stop_metadata} -> {result, measurements, Map.merge(start_metadata, stop_metadata)}
        {result, stop_metadata} -> {result, Map.merge(start_metadata, stop_metadata)}
      end
    end)
  end

  @doc false
  @spec request_span(map(), (-> {result, map(), map()})) :: result when result: term()
  def request_span(start_metadata, fun), do: span(@prefix, start_metadata, fun)
end
