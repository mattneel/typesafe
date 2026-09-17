# Questions

A question is a small, focused judgment about the state you send. TypeSafe has three question
types, called primitives. This guide covers how to build each one in Elixir, the criteria
shapes they accept, structured JSON, ids, and validation. For how to write good instructions
and pick a type, read TypeSafe's [Primitives](https://docs.typesafe.ai/primitives.md) page first.

| Primitive | Build with | Criteria | Answer |
| --- | --- | --- | --- |
| [Noul](https://docs.typesafe.ai/primitives/noul.md) | `TypeSafe.noul/2` | optional `%{true: ..., false: ...}` | `TypeSafe.Answer.Noul`: probability of yes |
| [Choice](https://docs.typesafe.ai/primitives/choice.md) | `TypeSafe.choice/3` | options, each with a description or `nil` | `TypeSafe.Answer.Choice`: top option, probabilities, confidence |
| [Score](https://docs.typesafe.ai/primitives/score.md) | `TypeSafe.score/3` | ordered list of at least two levels | `TypeSafe.Answer.Score`: weighted score, probabilities, confidence |

The constructors validate the question and raise `TypeSafe.Error` when it is invalid, which
suits questions written in code. `TypeSafe.Question.Noul.new/3`, `TypeSafe.Question.Choice.new/3`
and `TypeSafe.Question.Score.new/3` return `{:ok, question}` or `{:error, error}` instead, which
suits questions built from user input or a database.

## Noul

A Noul asks a yes/no question. The answer is the probability, from 0 to 1, that the answer is
yes.

```elixir
TypeSafe.noul("Does the customer request a refund?")

TypeSafe.noul("Does this convey urgency?",
  criteria: %{true: "Explicitly time-sensitive", false: "No urgency expressed"}
)
```

`:criteria` describes what yes and no mean. Either key can be left out. The keys can be the
atoms `true` and `false` or the strings `"true"` and `"false"`, in a map or a keyword list.
A Noul needs instructions or at least one criteria entry, so `TypeSafe.noul(nil)` is invalid.

## Choice

A Choice picks one option from a set you define. The answer has the top option, a probability
for every option, and a confidence.

```elixir
TypeSafe.choice("Which team should handle this?",
  billing: "Payments, invoicing, refunds",
  technical: "Bugs, outages, integrations",
  sales: "Pricing, upgrades, new accounts",
  other: nil
)
```

Criteria map each option to a description, or to `nil` when the option name says enough. You
can write them in four ways:

```elixir
# Keyword list: keeps your order
TypeSafe.choice("Tone?", calm: "Neutral wording", angry: "Hostile or insulting")

# List of {option, description} pairs: keeps your order, and allows string options
TypeSafe.choice("Tone?", [{"calm", "Neutral wording"}, {"angry", "Hostile or insulting"}])

# Map: sent sorted by option name
TypeSafe.choice("Tone?", %{calm: "Neutral wording", angry: "Hostile or insulting"})

# Plain list of options: each description is nil
TypeSafe.choice("Tone?", [:calm, :angry])
```

Options are atoms or non-empty strings. They are sent as strings and come back as whatever you
used, so `answer.choice` is `:calm` when you passed atoms and `"calm"` when you passed strings.
Two options with the same string form, such as `:calm` and `"calm"`, are rejected.

When the options might not cover every input, add an `other` option, as the TypeSafe docs
recommend. Otherwise the probability of an input that fits nowhere has to land on an option that
does not fit.

### Option order

Options are sent in the order you give them, and that order can move probabilities by a few
points. With the same text, the same instructions and the same three options, the order
alone changed the answer from `billing: 0.95` (billing listed first) to `billing: 0.97` (technical
listed first). The choice was the same in both cases, but a threshold near those values would
not have been.

Use a keyword list or a list of pairs when order matters, and keep the order stable between
calls whose answers you compare. A map is always sent sorted by option name, so it is also
stable, but in alphabetical order rather than yours.

### Passing options with a trailing keyword list

`TypeSafe.choice/3` takes criteria as its second argument and options such as `:extra` as its
third. When you write the criteria as a trailing keyword list without brackets, every key
becomes an option, including one named `extra`:

```elixir
# `extra` becomes a fourth option here
TypeSafe.choice("Tone?", calm: nil, angry: nil, extra: %{"hint" => "x"})

# Brackets separate criteria from options
TypeSafe.choice("Tone?", [calm: nil, angry: nil], extra: %{"hint" => "x"})
```

## Score

A Score rates the state against ordered levels you define. The answer has a probability-weighted
score, a probability for every level, and a confidence.

```elixir
TypeSafe.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
```

Criteria are a list of at least two levels. A level's position is its value, starting at 0, so
the score above runs from `0.0` to `2.0` and can land between levels, such as `1.05`. Levels can
be strings, maps or lists, but not `nil`, which the API rejects.

The answer's `legend` maps each level index back to the level you sent, and `probabilities` maps
each index to its probability. Both use integer keys:

```elixir
answer.probabilities[1]
#=> 0.95

TypeSafe.Answer.Score.expected_level(answer)
#=> {1, "Frustrated"}
```

## Structured JSON

State, instructions, Choice descriptions, Score levels and Noul criteria all accept JSON
structure: strings, maps, lists and `nil`, nested as deep as you need. Maps and lists are sent as
JSON objects and arrays, never as strings. Inside them, values can also be numbers, booleans,
atoms, or structs that implement `JSON.Encoder` such as `DateTime`. See
[State](https://docs.typesafe.ai/concepts/state.md) and
[Advanced: structure](https://docs.typesafe.ai/primitives/advanced.md) in the TypeSafe docs.

A structured state keeps related records together under descriptive names. Instructions can
point at one part of it with a path in backticks, as the TypeSafe docs describe:

```elixir
state = %{
  ticket: %{
    subject: "Duplicate charge",
    messages: [%{from: "customer", text: "I was charged twice for order A-104. Please refund one of them."}]
  },
  order: %{
    id: "A-104",
    charges: [%{amount: 49.0, at: "2026-09-14T10:02:00Z"}, %{amount: 49.0, at: "2026-09-14T10:02:03Z"}]
  },
  refund_policy: "Duplicate charges are eligible for a refund."
}

questions = [
  refund_requested: TypeSafe.noul("Does `ticket.messages[0].text` request a refund?"),
  policy_supports_refund:
    TypeSafe.noul(
      "Does `refund_policy` support the refund requested in `ticket.messages[0].text`, given `order.charges`?"
    ),
  resolution:
    TypeSafe.choice(
      %{task: "Pick the resolution for this ticket", constraints: ["Follow `refund_policy`"]},
      refund: %{action: "Refund the duplicate charge", requires: ["a duplicate charge", "the policy allows it"]},
      investigate: %{action: "Send to the payments team"},
      reply_only: nil
    ),
  effort:
    TypeSafe.score("How much agent effort does this ticket need?", [
      %{level: "none", example: "An automated reply"},
      %{level: "low", example: "One action in the admin panel"},
      %{level: "high", example: "An investigation across systems"}
    ])
]

{:ok, response} = TypeSafe.ask(client, state, questions)
```

The answers:

```elixir
%{
  refund_requested: %TypeSafe.Answer.Noul{noul: 0.99},
  policy_supports_refund: %TypeSafe.Answer.Noul{noul: 0.98},
  resolution: %TypeSafe.Answer.Choice{
    choice: :refund,
    confidence: 1.0,
    probabilities: %{refund: 1.0, investigate: 0.0, reply_only: 0.0}
  },
  effort: %TypeSafe.Answer.Score{
    score: 0.99,
    confidence: 0.99,
    legend: %{
      0 => %{"example" => "An automated reply", "level" => "none"},
      1 => %{"example" => "One action in the admin panel", "level" => "low"},
      2 => %{"example" => "An investigation across systems", "level" => "high"}
    },
    probabilities: %{0 => 0.01, 1 => 0.99, 2 => 0.0}
  }
}
```

The `legend` comes back from JSON, so map keys inside a level are strings even if you built the
level with atom keys.

## Question ids

Questions are keyed by ids you choose: atoms or non-empty strings, in a map or a keyword list.
Ids are for your code and are not sent to the model, so write the whole question in the
instructions.

- `response.answers` is always a map, keyed by the same ids with the same key type. Atom ids give
  atom keys, and string ids give string keys.
- A keyword list sends questions in your order. A map sends them sorted by id. Answers are
  independent of each other, so the order does not change the results.
- Two ids with the same string form, such as `:tone` and `"tone"`, are rejected, as is the empty
  string.

Use atoms for questions defined in code and strings for questions that come from data. Mixing
the two is legal but makes lookups easy to get wrong. `TypeSafe.Response.fetch!/2` raises a
`KeyError` that lists the ids that do have answers when a lookup misses.

## Validation

Questions and state are validated before anything is sent, so an invalid request fails in your
process without a network call.

The client-side checks include:

- at least one question, and every question is a TypeSafe question struct;
- ids are atoms or non-empty strings with no duplicates;
- Choice has at least one option, options are atoms or non-empty strings, and their string forms
  are unique;
- Score criteria is a list of at least two levels, with no `nil` level;
- Noul criteria keys are `true` or `false`, and a Noul has instructions or criteria;
- state and every value inside questions is JSON data (no PIDs, tuples or other non-JSON terms).

From `TypeSafe.ask/4`, a problem is an `:invalid_request` error. Its `path` locates the problem
inside the request, and `details` holds every issue found:

```elixir
iex> questions = %{rating: %TypeSafe.Question.Score{instructions: "Rate the answer", criteria: ["Good"]}}
iex> {:error, error} = TypeSafe.ask(client, "Thanks, that fixed it.", questions)
iex> {error.type, error.path, error.message}
{:invalid_request, ["questions", "rating", "criteria"], "score criteria needs at least two levels"}
```

The constructors raise the same error with a path relative to the question:

```elixir
iex> TypeSafe.score("How urgent is this?", ["Can wait"])
** (TypeSafe.Error) invalid_request: score criteria needs at least two levels at criteria
```

The tuple-returning constructors give the error without raising:

```elixir
iex> {:error, error} = TypeSafe.Question.Score.new("How urgent is this?", ["Can wait", nil])
iex> {error.path, error.message}
{["criteria", "1"], "expected a string, map or list (levels cannot be nil)"}
```

`TypeSafe.Question.validate/1` checks a question struct you built by hand.

The API validates too. A request the client accepts but the API rejects, such as an unknown
model, comes back as `:bad_request` or `:unprocessable` with the server's message and body.

## Extra wire fields

Every constructor accepts an `:extra` map of additional fields to send with the question. It
exists for API features newer than your version of the SDK:

```elixir
iex> TypeSafe.noul("Is this spam?", extra: %{"future_field" => true}) |> TypeSafe.Question.to_wire()
%{"future_field" => true, "instructions" => "Is this spam?", "type" => "noul"}
```

Extra field names are atoms or strings, values must be JSON, and `extra` cannot set `type`,
`instructions` or `criteria`.

## Unknown answer types

If the API returns an answer of a type this version of the SDK does not know, the answer is
skipped with a `Logger` warning instead of failing the whole response. The other answers decode
normally, and the unknown one stays readable in `response.raw["answers"]`. A new question type
on the server never breaks an existing client.

## Seeing what is sent

`TypeSafe.Question.to_wire/1` returns a question as the API's JSON structure. To validate
payloads outside Elixir, `mix typesafe.schema` writes JSON Schemas for the request and response
bodies to `priv/json_schema/`, and `mix typesafe.schema --check` fails when the checked-in files
are out of date.
