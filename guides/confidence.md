# Confidence

TypeSafe answers are probabilities, not verdicts. The SDK hands them to you unchanged, and your
code decides what is certain enough to act on. This guide covers how to read probabilities and
confidence, where thresholds belong, and how to route uncertain cases. The concepts come from
TypeSafe's [Confidence](https://docs.typesafe.ai/confidence.md) page and the
[Confidence-gated routing](https://docs.typesafe.ai/patterns/confidence-routing.md) pattern.

## Probability and confidence

Each answer type carries a different signal:

- A **Noul** answer is one probability: `noul` is how likely the answer is yes. A value near 1 is
  a strong yes, near 0 a strong no, and near 0.5 means the model gives yes and no about equal
  weight. Noul answers have no separate confidence.
- A **Choice** answer has `probabilities` across your options, and `choice` is the most likely
  one.
- A **Score** answer has `probabilities` across your levels, and `score` is the
  probability-weighted position along them.

Choice and Score answers also carry `confidence`, a number from 0 to 1 that TypeSafe derives
from the shape of the distribution. A distribution concentrated on one outcome gives high
confidence, and a flat one gives low confidence. TypeSafe does not publish the exact formula,
and this SDK does not recompute or adjust it. If a different measure suits your problem better,
compute it from `probabilities`, which are always included.

Confidence is not the top probability. These are real answers to a department question like the one
in [Getting started](getting-started.md) (billing, technical or sales) for three messages:

| Message | Probabilities | `confidence` | `margin/1` |
| --- | --- | --- | --- |
| "Help! My payouts have been failing for 3 days." | billing 0.87, technical 0.13, sales 0.0 | 0.81 | 0.74 |
| "I want to talk to someone about my invoice and the API limits on our plan." | billing 0.89, sales 0.1, technical 0.01 | 0.82 | 0.79 |
| "Hello?" | technical 0.67, sales 0.33, billing 0.0 | 0.5 | 0.34 |

"Hello?" has no department, and its top option still has a probability of 0.67. Acting on
`choice` alone would send it to the technical team. The confidence of 0.5 and the margin of 0.34
show that the model is not sure.

## Thresholds belong in your code

The SDK has no thresholds, so nothing is decided behind your back. Put thresholds next to the
actions they gate, and scale them with the cost of a mistake. A wrong read-only action is cheap,
while a wrong refund or deletion is not:

```elixir
defmodule MyApp.Support.Router do
  alias TypeSafe.Answer.Choice
  alias TypeSafe.Answer.Noul

  # Below these, a person decides.
  @min_confidence 0.6
  @min_margin 0.2

  # Refunds move money, so they need more certainty to run without confirmation.
  @refund_confidence 0.85

  @questions [
    intent:
      TypeSafe.choice("What does the customer want?",
        refund: "Money returned for a charge",
        order_status: "Where an order is or when it arrives",
        how_to: "Help using the product",
        other: nil
      ),
    is_urgent: TypeSafe.noul("Does this convey urgency?")
  ]

  def route(text) do
    with {:ok, %TypeSafe.Response{answers: answers}} <- TypeSafe.ask(TypeSafe.new(), text, @questions) do
      {:ok, decide(answers)}
    end
  end

  def decide(%{intent: %Choice{} = intent, is_urgent: %Noul{} = urgent}) do
    priority = if Noul.yes?(urgent, 0.8), do: :high, else: :normal

    cond do
      intent.confidence < @min_confidence or Choice.margin(intent) < @min_margin ->
        {:human_review, priority, Choice.ranked(intent)}

      intent.choice == :other ->
        {:human_review, priority, Choice.ranked(intent)}

      intent.choice == :refund and intent.confidence < @refund_confidence ->
        {:confirm_with_customer, :refund, priority}

      true ->
        {:automate, intent.choice, priority}
    end
  end
end
```

`decide/1` is a pure function of answer structs, so you can test every branch without HTTP (see
[Testing](testing.md)).

Start with conservative thresholds, then adjust them against your own data. The TypeSafe docs
are explicit that correct values depend on your domain and on how the model performs for your
use case.

## Reading Choice answers

`TypeSafe.Answer.Choice.ranked/1` lists `{option, probability}` pairs from most to least likely,
and `TypeSafe.Answer.Choice.margin/1` returns the top probability minus the second:

```elixir
TypeSafe.Answer.Choice.ranked(answer)
#=> [technical: 0.67, sales: 0.33, billing: 0.0]

TypeSafe.Answer.Choice.margin(answer)
#=> 0.34
```

The margin tells you whether the model is split between two specific options. That can matter
more than overall confidence. A ticket split between `billing` and `sales` can go to either team
with a note, while a ticket split between `refund` and `order_status` needs a person. The ranked
list is also a useful payload for a review queue, because it shows the reviewer what the model
considered.

## Reading Noul answers

A Noul has no confidence field. The probability is the whole signal, so use two thresholds and
treat the middle as "not sure". `TypeSafe.Answer.Noul.yes?/2` compares against a threshold
(default `0.5`):

```elixir
def urgency(%TypeSafe.Answer.Noul{} = answer) do
  cond do
    TypeSafe.Answer.Noul.yes?(answer, 0.8) -> :urgent
    TypeSafe.Answer.Noul.yes?(answer, 0.2) -> :unsure
    true -> :not_urgent
  end
end
```

Asked "Does this convey urgency?", "Help! My payouts have been failing for 3 days." scored `0.95`
(`:urgent`) and "Hello?" scored `0.06` (`:not_urgent`). "Your docs say webhooks retry, but we
were billed for the failed calls." scored `0.71`, which lands in `:unsure`. That message is a
reasonable one to hand to a person or a slower check. A single threshold at 0.5 would have
labelled it urgent with no sign of doubt.

As the TypeSafe docs warn, a Noul of 0.5 means yes and no are equally likely. It does not mean
"somewhat". If you want a degree, such as how urgent or how skilled, ask a Score with defined
levels.

## Reading Score answers

`score` is a weighted average, so it can hide a split. Compare it with the distribution. Consider
an answer like this one for levels Calm, Frustrated and Very angry:

```elixir
answer = %TypeSafe.Answer.Score{
  score: 1.0,
  confidence: 0.3,
  legend: %{0 => "Calm", 1 => "Frustrated", 2 => "Very angry"},
  probabilities: %{0 => 0.45, 1 => 0.1, 2 => 0.45}
}

TypeSafe.Answer.Score.expected_level(answer)
#=> {1, "Frustrated"}

TypeSafe.Answer.Score.max_level(answer)
#=> {0, "Calm"}

TypeSafe.Answer.Score.ranked(answer)
#=> [{0, 0.45}, {2, 0.45}, {1, 0.1}]
```

The score rounds to "Frustrated", the least likely level. `TypeSafe.Answer.Score.expected_level/1`
rounds the score to the nearest level. `TypeSafe.Answer.Score.max_level/1` returns the single
most likely level, and ties go to the lower level. When the two disagree, or confidence is low,
the levels are probably ambiguous for this input, or the state does not contain enough to decide.

For a clear answer the helpers agree. The frustration answer for "Help! My payouts have been
failing for 3 days." was `score: 1.05` with probabilities `0.0`, `0.95` and `0.05`, and a
confidence of `0.93`. Both helpers return `{1, "Frustrated"}`.

When you threshold a Score, a threshold on `score` itself (for example, escalate above `1.5`)
works well once confidence is high enough to trust the position.

## Routing uncertain cases

Low confidence is useful output. It is the model saying "I don't know", and your code can send
those cases somewhere better equipped:

- **A person.** Put the case in a review queue with the ranked probabilities attached.
- **A slower model.** Send only the uncertain cases to a reasoning model or a larger pipeline.
  Most cases take the fast, cheap path, and the hard ones get more attention.
- **The user.** Ask a confirming question, as the refund branch above does.
- **More context.** Fetch more state, such as order history, and ask again.

```elixir
case MyApp.Support.Router.route(ticket.body) do
  {:ok, {:automate, intent, priority}} -> MyApp.Support.handle(ticket, intent, priority)
  {:ok, {:confirm_with_customer, intent, _priority}} -> MyApp.Support.ask_to_confirm(ticket, intent)
  {:ok, {:human_review, priority, ranked}} -> MyApp.ReviewQueue.push(ticket, priority, ranked)
  {:error, %TypeSafe.Error{} = error} -> MyApp.ReviewQueue.push(ticket, :normal, {:error, error.type})
end
```

A failed call is an uncertain case too. Once the client's retries are spent, sending the ticket
to a person is often better than dropping it. `TypeSafe.Error.retryable?/2` tells you whether
trying again later could help.

## Calibrating with your own data

Thresholds are guesses until you check them. Record enough with each decision to review it
later:

- the probabilities and confidence (or `ranked/1`) for each answer that drove the decision;
- `response.model`, the concrete model version such as `"jev-1.13.0"`, because answers can shift
  between versions;
- `response.request_id`, for support questions;
- what happened next: whether a reviewer agreed, or whether the automated action was reversed.

With a few hundred reviewed cases, you can see how often each confidence band was right and move
the thresholds to match your risk tolerance. The [Telemetry guide](telemetry.md) shows how to
tag events with your own ids through `:telemetry_metadata`, so decisions and calls can be joined.
