defmodule TypeSafe.DoctestTest do
  use ExUnit.Case, async: true

  doctest TypeSafe
  doctest TypeSafe.Answer
  doctest TypeSafe.Answer.Choice
  doctest TypeSafe.Answer.Noul
  doctest TypeSafe.Answer.Score
  doctest TypeSafe.Client
  doctest TypeSafe.Error
  doctest TypeSafe.Question
  doctest TypeSafe.Question.Choice
  doctest TypeSafe.Question.Noul
  doctest TypeSafe.Question.Score
  doctest TypeSafe.Req
  doctest TypeSafe.Response
  doctest TypeSafe.Retry
  doctest TypeSafe.Telemetry
  doctest TypeSafe.Test
end
