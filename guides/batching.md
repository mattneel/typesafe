# Batching and concurrency

There are two ways to do more work with TypeSafe: ask more questions per request, and send more
requests at once. Use the first wherever you can, and the second for the many independent states
that remain.

## Many questions, one request

Every question in a request sees the same state and is answered independently. One question's
answer does not affect another's, so batching does not change results. What batching changes is
cost and latency:

- The state is usually most of the input tokens. One request pays for it once, while N
  single-question requests pay for it N times.
- The questions in a request are evaluated in parallel, so adding questions barely changes
  response time.

TypeSafe's [Parallel questions](https://docs.typesafe.ai/cookbooks/parallel_questions.md)
cookbook measured this with 13 questions over a 54,000-character document. One batched call was
12.2x cheaper and 10x faster than 13 single-question calls, with no change in the answers.

In practice, build one question set per kind of state and send it whole:

```elixir
@questions %{
  refund_requested: TypeSafe.noul("Does the customer request a refund?"),
  is_urgent: TypeSafe.noul("Does this convey urgency?"),
  mentions_competitor: TypeSafe.noul("Does the customer mention switching to a competitor?"),
  department:
    TypeSafe.choice("Which team should handle this?",
      billing: "Payments, invoicing, refunds",
      technical: "Bugs, outages, integrations",
      sales: "Pricing, upgrades, new accounts",
      other: nil
    ),
  frustration: TypeSafe.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
}

TypeSafe.ask(client, ticket_state, @questions)
```

Ask questions you might not need, too. A question whose answer only matters for some inputs,
such as `mentions_competitor`, costs only its own few tokens. Your code reads it when it is
relevant. TypeSafe calls this [speculative fan-out](https://docs.typesafe.ai/patterns/fan-out.md).

The limit is the request's token budget, which the state and questions share. The TypeSafe docs
put it at around 32,000 tokens, roughly 150,000 characters of English text (see
[Ask multiple questions together](https://docs.typesafe.ai/primitives.md)). `response.usage`
reports the input and output tokens of each call.

## Many states, many requests

When the same questions run over many states, such as a backlog of tickets, send one request per
state and run them concurrently. `Task.async_stream/3` bounds the concurrency and keeps results
in input order:

```elixir
defmodule MyApp.Backfill do
  @questions %{
    is_urgent: TypeSafe.noul("Does this convey urgency?"),
    department:
      TypeSafe.choice("Which team should handle this?",
        billing: "Payments, invoicing, refunds",
        technical: "Bugs, outages, integrations",
        sales: "Pricing, upgrades, new accounts"
      )
  }

  def classify(tickets, opts \\ []) do
    client = TypeSafe.new()

    tickets
    |> Task.async_stream(
      fn ticket -> TypeSafe.ask(client, ticket.body, @questions, telemetry_metadata: %{ticket_id: ticket.id}) end,
      max_concurrency: Keyword.get(opts, :max_concurrency, 20),
      timeout: 60_000,
      on_timeout: :kill_task
    )
    |> Enum.zip_with(tickets, fn
      {:ok, {:ok, response}}, ticket -> {ticket.id, {:ok, response.answers}}
      {:ok, {:error, error}}, ticket -> {ticket.id, {:error, error}}
      {:exit, reason}, ticket -> {ticket.id, {:error, {:exit, reason}}}
    end)
  end
end
```

Notes on this pattern:

- **Share one client.** A client is an immutable value, so build it once and let every task close
  over it. Tasks do not need their own clients.
- **Set `:timeout`.** `Task.async_stream/3` defaults to 5 seconds per task, and a slow call or a
  retry wait would exit the caller. Each TypeSafe call is already bounded by the client's
  timeouts and its 30 s retry budget. The task timeout is a backstop, and `on_timeout: :kill_task`
  turns a stuck task into an `{:exit, :timeout}` result instead of a crash.
- **Handle errors per item.** A rate limit or a timeout on one ticket should not lose the rest of
  the batch. Collect the errors and retry them later.
- **Pick `max_concurrency` deliberately.** Start low, watch for `:rate_limited` errors and
  retries (see below), and raise it gradually. Keep it at or below your connection pool size.

## Rate limits and retries

A 429 or 529 response is retried by the client's policy, which waits for the server's
`Retry-After` when it is sent. Under sustained high concurrency, some calls can still run out of
retries or budget and return `{:error, %TypeSafe.Error{type: :rate_limited}}` or `:overloaded`.
That is a signal to lower `max_concurrency`, not to add more retries.

The `:retries` count on the `[:typesafe, :request, :stop]` telemetry event shows pressure before
errors appear. A rising share of calls with `retries > 0` means the batch is running too hot. See
[Telemetry](telemetry.md).

For a background backfill, you can trade latency for fewer failures with a more patient policy:

```elixir
client = TypeSafe.new(retry: [max_retries: 5, backoff_max_ms: 10_000, budget_ms: 120_000])
```

Raise the task `:timeout` to match when you raise `budget_ms`.

## Connection pools

By default, requests go through Req's HTTP/1 Finch pool. It opens at most 50 connections to one
host (Finch's default `size`), so at most 50 TypeSafe calls can be in flight at once. With
`max_concurrency` above 50, the extra calls wait for a free connection. A call that waits longer
than Finch's `:pool_timeout` (5 seconds by default) returns
`{:error, %TypeSafe.Error{type: :transport, reason: :pool_timeout}}`. That error is not retried
inside the call, because the wait already happened, but `TypeSafe.Error.retryable?/1` returns
`true` for it. Keep concurrency at or below the pool size.

For more concurrency, or to keep TypeSafe traffic apart from your other HTTP calls, start your
own Finch pool in your supervision tree and pass its name to the client:

```elixir
# lib/my_app/application.ex
children = [
  {Finch,
   name: MyApp.Finch,
   pools: %{
     "https://api.typesafe.ai" => [size: 100, conn_opts: [transport_opts: [timeout: 10_000]]]
   }},
  # ...
]
```

```elixir
client = TypeSafe.new(finch: [name: MyApp.Finch])
```

The client's `:timeout` applies to receiving each response. The connect timeout comes from the
pool (or from `req_options: [connect_options: [timeout: ...]]` with Req's own pools), which is why
the example sets `conn_opts: [transport_opts: [timeout: 10_000]]` to match the client default.

api.typesafe.ai also speaks HTTP/2, where one connection multiplexes many concurrent requests. An
HTTP/2 pool ignores `:size`, and `:count` sets how many connections it opens:

```elixir
{Finch,
 name: MyApp.Finch,
 pools: %{
   "https://api.typesafe.ai" => [protocols: [:http2], count: 2]
 }}
```

An HTTP/2 pool connects in the background when Finch starts. A request sent before the connection
is ready fails with a `Req.HTTPError` (`:pool_not_available`), which the default retry policy
retries as a transport error. Check the pool options against the
[Finch documentation](https://hexdocs.pm/finch/Finch.html#start_link/1-pool-configuration-options)
for the Finch version you run.

Finch emits `[:finch, :queue, :stop]` events with the time each HTTP/1 request waited for a
connection. Sustained queue time means the pool is smaller than your concurrency.

## Broadway and other pipelines

In a Broadway pipeline, each message usually carries its own state, so each message is one
`TypeSafe.ask/4` call. The processor `concurrency` plays the role of `max_concurrency`, and the
same pool sizing applies. Build the questions once, as a module attribute, and send every
question the pipeline needs in that one call.

If your application already has a configured `Req.Request` with shared pools, tracing steps or a
custom adapter, `TypeSafe.Req.attach/2` adds TypeSafe to it instead of creating a second client,
and `TypeSafe.Req.decode/2` turns the result into a `TypeSafe.Response`:

```elixir
req =
  Req.new(finch: [name: MyApp.Finch])
  |> TypeSafe.Req.attach(api_key: System.fetch_env!("TYPESAFE_API_KEY"))

questions = %{is_urgent: TypeSafe.noul("Does this convey urgency?")}

req
|> Req.post(typesafe_state: "Help! My payouts are failing.", typesafe_questions: questions)
|> TypeSafe.Req.decode(questions)
```

The API key, identification headers and TypeSafe retry policy apply only to requests that set
`:typesafe_questions`; every other request through the same `Req.Request` is left alone. The
response body stays raw JSON text until `TypeSafe.Req.decode/2` decodes it.

Calls made this way do not emit `[:typesafe, :request, ...]` telemetry events, because your Req
pipeline owns the request.
