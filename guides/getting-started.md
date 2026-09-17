# Getting started

This guide takes you from installation to a first set of answers, and shows where the pieces
go in a Mix project. For what System One is and when to use it, read TypeSafe's
[introduction](https://docs.typesafe.ai/introduction.md) and
[How to build with TypeSafe](https://docs.typesafe.ai/concepts/how-to-build-with-system-one.md).

## Install

Add the dependency and fetch it:

```elixir
def deps do
  [
    {:typesafe, "~> 0.1.0"}
  ]
end
```

```console
$ mix deps.get
```

TypeSafe needs Elixir 1.18 or later and Erlang/OTP 27 or later.

## Set your API key

Create a key as described in the [TypeSafe quick start](https://docs.typesafe.ai/introduction/quickstart.md)
and export it:

```console
$ export TYPESAFE_API_KEY=...
```

`TypeSafe.new/1` reads `TYPESAFE_API_KEY` when you do not pass `:api_key`. You can also set it
in application config, which is useful when the key comes from a secret store:

```elixir
# config/runtime.exs
config :typesafe, api_key: System.get_env("TYPESAFE_API_KEY")
```

An explicit option wins over the environment variable, and the environment variable wins over
application config. A client with no key anywhere raises `ArgumentError` when it is built, not
on the first request.

## Ask a first question

Start `iex -S mix`, build a client and ask one Noul (yes/no) question:

```elixir
iex> client = TypeSafe.new()
iex> TypeSafe.ask(client, "Limited offer! Buy 3 get 1 free, click now.", %{
...>   spam: TypeSafe.noul("Is this unsolicited advertising?")
...> })
{:ok,
 %TypeSafe.Response{
   model: "jev-1.13.0",
   request_id: "req_01a0ac9ee6e476b894913942ccab3d77",
   raw: %{...},
   answers: %{spam: %TypeSafe.Answer.Noul{noul: 0.82}},
   usage: %TypeSafe.Usage{input_tokens: 287, output_tokens: 20}
 }}
```

The request has three parts:

- **State** is the content to judge: here a string. It can also be a map or a list, which is
  sent as JSON structure. See [State](https://docs.typesafe.ai/concepts/state.md).
- **Questions** is a map (or keyword list) of questions keyed by ids you choose. The ids are
  not sent to the model.
- **Answers** come back under the same ids, with the same key type.

`noul` is the probability that the answer is yes. What counts as "yes" for your application is
decided in your code, as the [Confidence guide](confidence.md) explains.

## Ask several questions at once

Every question in a request sees the same state and is answered independently, so send all the
questions you have about one state together. Mixing types is fine:

```elixir
questions = %{
  is_urgent:
    TypeSafe.noul("Does this convey urgency?",
      criteria: %{true: "Explicitly time-sensitive", false: "No urgency expressed"}
    ),
  department:
    TypeSafe.choice("Which team should handle this?",
      billing: "Payments, invoicing, refunds",
      technical: "Bugs, outages, integrations",
      sales: nil
    ),
  frustration: TypeSafe.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
}

{:ok, response} = TypeSafe.ask(client, "Help! My payouts have been failing for 3 days.", questions)
```

The response for this request:

```elixir
%TypeSafe.Response{
  model: "jev-1.13.0",
  request_id: "req_01a0ac97618c76898e35b41bf6d9aa5e",
  raw: %{...},
  answers: %{
    is_urgent: %TypeSafe.Answer.Noul{noul: 0.95},
    department: %TypeSafe.Answer.Choice{
      choice: :billing,
      confidence: 0.81,
      probabilities: %{billing: 0.87, technical: 0.13, sales: 0.0}
    },
    frustration: %TypeSafe.Answer.Score{
      score: 1.05,
      confidence: 0.93,
      legend: %{0 => "Calm", 1 => "Frustrated", 2 => "Very angry"},
      probabilities: %{0 => 0.0, 1 => 0.95, 2 => 0.05}
    }
  },
  usage: %TypeSafe.Usage{input_tokens: 414, output_tokens: 73}
}
```

- `TypeSafe.noul/2` asks a yes/no question. `:criteria` optionally describes what yes (`true`)
  and no (`false`) mean.
- `TypeSafe.choice/3` picks one option. Criteria map each option to a description, or to `nil`
  when the name says enough. A keyword list keeps your option order.
- `TypeSafe.score/3` rates the state against an ordered list of at least two levels. The score
  is probability-weighted, so it can land between levels, as `1.05` does here.

The [Questions guide](questions.md) covers every criteria shape, structured JSON and validation.

## Read the answers

Answers are plain structs, so pattern matching and field access both work:

```elixir
%{department: department, frustration: frustration} = response.answers

department.choice
#=> :billing

TypeSafe.Answer.Choice.ranked(department)
#=> [billing: 0.87, technical: 0.13, sales: 0.0]

TypeSafe.Answer.Choice.margin(department)
#=> 0.74

TypeSafe.Answer.Score.expected_level(frustration)
#=> {1, "Frustrated"}

TypeSafe.Answer.Noul.yes?(response.answers.is_urgent, 0.8)
#=> true
```

`TypeSafe.Response.fetch!/2` raises a `KeyError` that lists the ids that do have answers, which
catches a typo or an atom and string mix-up:

```elixir
TypeSafe.Response.fetch!(response, "department")
** (KeyError) no TypeSafe answer for question id "department"; answers exist for [:department, :frustration, :is_urgent]
```

## Handle errors

`TypeSafe.ask/4` returns `{:error, %TypeSafe.Error{}}` for every failure. Match on `:type`:

```elixir
case TypeSafe.ask(client, ticket.body, questions) do
  {:ok, response} ->
    {:ok, route(response.answers)}

  {:error, %TypeSafe.Error{type: type} = error} when type in [:rate_limited, :overloaded, :timeout] ->
    # Already retried by the client's policy; try again later.
    {:retry_later, error}

  {:error, %TypeSafe.Error{} = error} ->
    Logger.error(Exception.message(error))
    {:error, error}
end
```

Transient failures are retried for you before `ask/4` returns. `TypeSafe.ask!/4` returns the
response directly and raises the error instead, which suits scripts and one-off tasks. See
`TypeSafe.Error` for every type, and `TypeSafe.Retry` for the retry policy.

## Keep a client in your application

A client is an immutable value. It holds no process and needs no supervision, and building one
does no I/O. A small module that owns your questions and builds the client from config keeps
call sites short and lets tests swap the transport through config:

```elixir
defmodule MyApp.Triage do
  @questions %{
    is_urgent: TypeSafe.noul("Does this convey urgency?"),
    department:
      TypeSafe.choice("Which team should handle this?",
        billing: "Payments, invoicing, refunds",
        technical: "Bugs, outages, integrations",
        sales: "Pricing, upgrades, new accounts"
      )
  }

  def classify(text, opts \\ []) do
    TypeSafe.ask(client(), text, @questions, opts)
  end

  defp client, do: TypeSafe.new()
end
```

Questions are plain structs, so they can live in module attributes. Build the client at
runtime, as `client/0` does, rather than in a module attribute: its `Req.Request` holds
functions that cannot be stored at compile time, and config such as the test transport is only
read when the client is built. When you make many calls in a loop, build the client once and
pass it along.

## Choose a model

The client uses `"jev-latest"` unless you set `:model` on the client, `TYPESAFE_DEFAULT_MODEL`,
or `config :typesafe, model: ...`. You can also override it for one call:

```elixir
TypeSafe.ask(client, text, questions, model: "jev-preview")
```

`TypeSafe.list_models/2` returns what your account can use:

```elixir
iex> TypeSafe.list_models(client)
{:ok,
 [
   %TypeSafe.Model{
     name: "jev-latest",
     description: "The latest iteration of TypeSafe's System One Model: Jev",
     release_date: "2026-09-10T18:38:01.391457+00:00"
   },
   %TypeSafe.Model{
     name: "jev-preview",
     description: "A preview version of `jev-latest`: should be better in most ways",
     release_date: "2026-09-10T18:39:06.057655+00:00"
   }
 ]}
```

`response.model` reports the concrete version that answered, such as `"jev-1.13.0"`. Log it
next to decisions you store, so you can tell which model version made them.

## Next steps

- [Questions](questions.md): criteria shapes, structured JSON, ids and validation.
- [Confidence](confidence.md): turn probabilities into decisions, and route uncertain cases.
- [Batching and concurrency](batching.md): many questions per request, many requests at once.
- [Testing](testing.md): stub TypeSafe in `async: true` tests.
- [Telemetry](telemetry.md): logs, metrics and token usage.
