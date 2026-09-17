# Testing

TypeSafe runs on [Req](https://hexdocs.pm/req), so tests replace the HTTP layer with
`Req.Test` stubs. The tests then run without the network, with `async: true`, and with
answers you choose. `TypeSafe.Test` builds stubs that answer the way the API does.

## Setup

Route every client through `Req.Test` in `config/test.exs`:

```elixir
# config/test.exs
config :typesafe,
  api_key: "test",
  retry: false,
  req_options: [plug: {Req.Test, TypeSafe}]
```

- `api_key: "test"` means clients can be built without a real key. The key never leaves the
  process, because the plug replaces the network.
- `retry: false` makes an error stub fail at once instead of waiting out backoff delays.
- `req_options: [plug: {Req.Test, TypeSafe}]` sends requests to the `Req.Test` stub named
  `TypeSafe`, which the helpers install.

`:req_options` from config and from `TypeSafe.new/1` are merged, so the plug stays in place even
when your code passes its own `req_options`. Other options follow the usual order: an explicit
option beats a `TYPESAFE_*` environment variable, which beats config. For this setup to apply,
your code must build its clients at runtime (see
[Getting started](getting-started.md#keep-a-client-in-your-application)).

`TypeSafe.Test` is compiled when `Plug` is available. `Req.Test` needs Plug too, so add it as a
test dependency if you do not have it already:

```elixir
{:plug, "~> 1.20", only: :test}
```

## Stubbing answers

`TypeSafe.Test.stub_answers/2` stubs `POST /v1/systemone` for the current test:

```elixir
defmodule MyApp.EscalationTest do
  use ExUnit.Case, async: true

  test "pages on-call for urgent technical tickets" do
    TypeSafe.Test.stub_answers(%{
      is_urgent: {:noul, 0.92},
      department: {:choice, :technical, %{billing: 0.08, technical: 0.85, sales: 0.07}, 0.82}
    })

    assert MyApp.Escalation.route("The API returns 500 on every request.") == {:page, :on_call}
  end
end
```

Each answer is a tuple or an answer struct:

| Spec | Example |
| --- | --- |
| `{:noul, probability}` | `{:noul, 0.92}` |
| `{:choice, choice, probabilities}` | `{:choice, :billing, %{billing: 0.9, sales: 0.1}}` |
| `{:choice, choice, probabilities, confidence}` | `{:choice, :billing, %{billing: 0.9, sales: 0.1}, 0.84}` |
| `{:score, score, legend, probabilities}` | `{:score, 1.6, ["Calm", "Frustrated", "Very angry"], %{0 => 0.05, 1 => 0.3, 2 => 0.65}}` |
| `{:score, score, legend, probabilities, confidence}` | the same with a confidence as the last element |
| an answer struct | `%TypeSafe.Answer.Noul{noul: 0.92}` |

A Score `legend` is a list of levels or a map of level index to level.

When you leave out `confidence`, the stub uses the top probability as a placeholder. TypeSafe
does not publish how confidence is derived, so the placeholder is not what the API would return.
Set `confidence` explicitly in any test whose code path depends on it.

`stub_answers/2` also accepts `:model`, `:usage` and `:request_id` options, for code that logs
or stores them:

```elixir
TypeSafe.Test.stub_answers(%{is_urgent: {:noul, 0.92}},
  model: "jev-1.13.0",
  usage: %{input_tokens: 414, output_tokens: 73},
  request_id: "req_test_triage"
)
```

### The stub checks what your code sends

The stub compares the question ids in the request with the stubbed ids, and each question's type
with its stubbed answer. A renamed, added or retyped question fails the test with a clear message
instead of silently returning nothing:

```text
TypeSafe.Test: the question ids sent do not match the stubbed answers.

  sent but not stubbed: ["dept"]
  stubbed but not sent: ["department", "is_urgent"]
```

To assert on the request body itself, such as the state your code built, write a `Req.Test` stub
that inspects the body and then delegates to `TypeSafe.Test.answers_plug/2`:

```elixir
test "sends the subject and body as structured state" do
  Req.Test.stub(TypeSafe, fn conn ->
    body = conn |> Req.Test.raw_body() |> IO.iodata_to_binary() |> JSON.decode!()
    assert body["state"] == %{"subject" => "Refund", "body" => "I was charged twice."}
    assert body["model"] == "jev-latest"

    TypeSafe.Test.answers_plug(%{is_refund: {:noul, 0.97}}).(conn)
  end)

  assert {:ok, :refund} = MyApp.Tickets.classify(%{subject: "Refund", body: "I was charged twice."})
end
```

## Stubbing errors

`TypeSafe.Test.stub_error/2` makes every request fail with an HTTP status, and
`TypeSafe.Test.stub_transport_error/2` makes it fail before a response arrives:

```elixir
test "reports the server's requested wait when rate limited" do
  TypeSafe.Test.stub_error(429, retry_after_ms: 1200)
  assert {:error, %TypeSafe.Error{type: :rate_limited, retry_after_ms: 1200}} = MyApp.Triage.classify("Hello")
end

test "keeps the server's validation details" do
  TypeSafe.Test.stub_error(422, body: %{"detail" => [%{"loc" => ["body", "questions"], "msg" => "Field required"}]})
  assert {:error, %TypeSafe.Error{type: :unprocessable}} = MyApp.Triage.classify("Hello")
end

test "survives a timeout" do
  TypeSafe.Test.stub_transport_error(:timeout)
  assert {:error, %TypeSafe.Error{type: :timeout}} = MyApp.Triage.classify("Hello")
end
```

`:retry_after_ms` sets both the `retry-after-ms` and `Retry-After` headers. Error stubs also take
`:body`, `:headers` and `:request_id`.

## Testing retries and sequences

`TypeSafe.Test.answers_plug/2` and `TypeSafe.Test.error_plug/2` return the plugs that the stub
functions install. Combine them with `Req.Test.expect/3` to script responses in order. Retries are
off in the test config, so build a client with retries on and no backoff for this kind of test:

```elixir
test "recovers from an overloaded response" do
  client = TypeSafe.new(retry: [backoff_initial_ms: 0])

  Req.Test.expect(TypeSafe, TypeSafe.Test.error_plug(529))
  Req.Test.expect(TypeSafe, TypeSafe.Test.answers_plug(%{is_urgent: {:noul, 0.9}}))

  assert {:ok, response} = TypeSafe.ask(client, "Hello", %{is_urgent: TypeSafe.noul("Is this urgent?")})
  assert response.answers.is_urgent.noul == 0.9
end
```

A 429 or 529 stub with `:retry_after_ms` makes the retry wait that long. Pass
`retry: [backoff_initial_ms: 0, respect_retry_after: false]` to keep such tests fast.

## Models

`TypeSafe.Test.stub_models/2` stubs `GET /v1/models`:

```elixir
TypeSafe.Test.stub_models([
  %{name: "jev-latest", description: "The latest iteration of TypeSafe's System One Model: Jev", release_date: "2026-09-10T18:38:01.391457+00:00"}
])
```

## Testing decisions without HTTP

Keep the logic that turns answers into actions in a pure function, and test it with answer
structs. Such tests cover every threshold and branch, including rare confidence bands, with no
stubs at all:

```elixir
alias TypeSafe.Answer.Choice
alias TypeSafe.Answer.Noul

test "a split between two intents goes to a person" do
  intent = %Choice{choice: :refund, probabilities: %{refund: 0.52, order_status: 0.48}, confidence: 0.41}

  assert {:human_review, :normal, _ranked} =
           MyApp.Support.Router.decide(%{intent: intent, is_urgent: %Noul{noul: 0.1}})
end
```

The [Confidence guide](confidence.md) shows the router this test exercises.

## Calls from other processes

`Req.Test` stubs belong to the test process, using the same ownership model as Mox. Processes
started with `Task.async/1` or `Task.async_stream/3` from the test process can use its stubs
automatically.

A process that is not started from the test, such as a GenServer under your application
supervisor, needs an explicit allowance:

```elixir
test "the worker classifies queued tickets" do
  TypeSafe.Test.stub_answers(%{is_urgent: {:noul, 0.2}})

  pid = Process.whereis(MyApp.TriageWorker)
  Req.Test.allow(TypeSafe, self(), pid)

  assert {:ok, :normal} = MyApp.TriageWorker.classify(pid, "Where is my invoice?")
end
```

For Broadway, allow each processor when it starts handling a test message. Pass the test pid in
the message metadata and attach a telemetry handler in `test/test_helper.exs`:

```elixir
# in the test
Broadway.test_message(MyApp.Pipeline, ticket, metadata: %{req_stub_owner: self()})

# test/test_helper.exs
defmodule MyApp.BroadwayReqStubs do
  def attach(stub) do
    events = [[:broadway, :processor, :start], [:broadway, :batch_processor, :start]]
    :telemetry.attach_many({__MODULE__, stub}, events, &__MODULE__.handle_event/4, %{stub: stub})
  end

  def handle_event(_event, _measurements, %{messages: messages}, %{stub: stub}) do
    with [%Broadway.Message{metadata: %{req_stub_owner: pid}} | _] <- messages do
      :ok = Req.Test.allow(stub, pid, self())
    end

    :ok
  end
end

MyApp.BroadwayReqStubs.attach(TypeSafe)
```

This follows the pattern in the `Req.Test` documentation. Tests that cannot use allowances can
share stubs globally with `Req.Test.set_req_test_to_shared/1`, but those tests must not be
`async: true`.

## Testing telemetry

`:telemetry_test` from the `telemetry` package forwards events to the test process:

```elixir
test "reports the ticket id with each call" do
  ref = :telemetry_test.attach_event_handlers(self(), [[:typesafe, :request, :stop]])
  TypeSafe.Test.stub_answers(%{is_urgent: {:noul, 0.92}})

  MyApp.Triage.classify("Hello", telemetry_metadata: %{ticket_id: 42})

  assert_received {[:typesafe, :request, :stop], ^ref, _measurements,
                   %{result: :ok, telemetry_metadata: %{ticket_id: 42}}}
end
```
