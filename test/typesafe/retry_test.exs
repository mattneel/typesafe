defmodule TypeSafe.RetryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog
  import TypeSafe.TestHelpers, only: [client: 0, client: 1]
  import TypeSafe.TransportHelpers

  alias TypeSafe.Error
  alias TypeSafe.Response
  alias TypeSafe.Retry

  @moduletag :capture_log

  @fast [backoff_initial_ms: 0, budget_ms: nil]

  describe "new/1" do
    test "defaults match TypeSafe's official Python and JavaScript SDKs" do
      assert Retry.new() == %Retry{
               max_retries: 2,
               backoff_initial_ms: 500,
               backoff_max_ms: 5_000,
               jitter: 0.25,
               statuses: [408, 429, 500..599],
               respect_retry_after: true,
               max_retry_after_ms: 60_000,
               retry_transport_errors: true,
               budget_ms: 30_000
             }

      assert Retry.new() == %Retry{}
    end

    test "applies overrides and returns a valid existing policy unchanged" do
      policy = Retry.new(max_retries: 4, backoff_initial_ms: 100, statuses: [409, 520..524], jitter: 0)

      assert %Retry{max_retries: 4, backoff_initial_ms: 100, statuses: [409, 520..524], jitter: 0} = policy
      assert Retry.new(policy) == policy
      assert Retry.new(%Retry{budget_ms: nil}) == %Retry{budget_ms: nil}
    end

    test "validates a hand-built policy struct" do
      cases = [
        {%Retry{jitter: 3}, ~r/jitter/},
        {%Retry{max_retries: -1}, ~r/max_retries/},
        {%Retry{backoff_initial_ms: 1.5}, ~r/backoff_initial_ms/},
        {%Retry{statuses: 500..599}, ~r/statuses/},
        {%Retry{statuses: [700]}, ~r/expected HTTP status codes/},
        {%Retry{budget_ms: 0}, ~r/budget_ms/}
      ]

      for {policy, message} <- cases do
        error = assert_raise ArgumentError, message, fn -> Retry.new(policy) end
        assert error.message =~ "invalid TypeSafe.Retry options"
      end
    end

    test "raises ArgumentError for an argument that is neither a keyword list nor a policy" do
      for other <- [%{max_retries: 1}, nil, 3, "fast"] do
        assert_raise ArgumentError, ~r/expected a keyword list or a %TypeSafe.Retry\{\}/, fn -> Retry.new(other) end
      end
    end

    test "the struct, its defaults and its type come from the option schema" do
      {:ok, defaults} = Zoi.parse(Retry.schema(), [])
      assert Map.from_struct(%Retry{}) == Map.new(defaults)
      schema_keys = defaults |> Keyword.keys() |> Enum.sort()

      {:ok, types} = Code.Typespec.fetch_types(Retry)
      assert [{:type, {:t, {:type, _, :map, fields}, []}}] = Enum.filter(types, &match?({:type, {:t, _, _}}, &1))

      type_keys = for {:type, _, :map_field_exact, [{:atom, _, key}, _value]} <- fields, key != :__struct__, do: key
      assert Enum.sort(type_keys) == schema_keys
    end

    test "budget_ms: nil disables the budget" do
      assert Retry.new(budget_ms: nil).budget_ms == nil
      assert Retry.new(budget_ms: 1_000).budget_ms == 1_000
    end

    test "raises ArgumentError for invalid options" do
      cases = [
        {[retries: 3], ~r/unrecognized key: retries/},
        {[max_retries: -1], ~r/max_retries/},
        {[max_retries: 1.5], ~r/max_retries/},
        {[backoff_initial_ms: -1], ~r/backoff_initial_ms/},
        {[backoff_max_ms: -5], ~r/backoff_max_ms/},
        {[jitter: 1.5], ~r/jitter/},
        {[jitter: -0.1], ~r/jitter/},
        {[statuses: 500..599], ~r/statuses/},
        {[statuses: [99]], ~r/expected HTTP status codes/},
        {[statuses: [600]], ~r/expected HTTP status codes/},
        {[statuses: [400..700]], ~r/expected HTTP status codes/},
        {[statuses: ["503"]], ~r/expected HTTP status codes/},
        {[respect_retry_after: "yes"], ~r/respect_retry_after/},
        {[max_retry_after_ms: -1], ~r/max_retry_after_ms/},
        {[retry_transport_errors: nil, budget_ms: 0], ~r/budget_ms/},
        {[:fast], ~r/expected a keyword list/}
      ]

      for {opts, message} <- cases do
        error = assert_raise ArgumentError, message, fn -> Retry.new(opts) end
        assert error.message =~ "invalid TypeSafe.Retry options"
      end
    end
  end

  describe "merge/2" do
    test "merges options over a policy, keeping its other fields" do
      base = Retry.new(max_retries: 4, statuses: [409], budget_ms: nil)

      assert Retry.merge(base, max_retries: 1) == %{base | max_retries: 1}
      assert Retry.merge(base, budget_ms: 500) == %{base | budget_ms: 500}
      assert Retry.merge(base, []) == base
    end

    test "merges over the defaults when the base is false, and validates the result" do
      assert Retry.merge(false, max_retries: 1) == %Retry{max_retries: 1}
      assert_raise ArgumentError, ~r/jitter/, fn -> Retry.merge(%Retry{}, jitter: 2) end
    end
  end

  describe "retryable?/2 and retryable_status?/2" do
    test "the default policy retries 408, 429 and every 5xx" do
      for status <- [408, 429, 500, 502, 503, 504, 520, 529, 599] do
        assert Retry.retryable_status?(%Retry{}, status), "expected #{status} to be retryable"
        assert Retry.retryable?(%Retry{}, Req.Response.new(status: status))
      end

      for status <- [200, 301, 400, 401, 403, 404, 409, 422, 499] do
        refute Retry.retryable_status?(%Retry{}, status), "expected #{status} not to be retryable"
        refute Retry.retryable?(%Retry{}, Req.Response.new(status: status))
      end
    end

    test "custom statuses accept integers and ranges" do
      policy = Retry.new(statuses: [409, 520..522])

      assert Retry.retryable_status?(policy, 409)
      assert Retry.retryable_status?(policy, 521)
      refute Retry.retryable_status?(policy, 523)
      refute Retry.retryable_status?(policy, 500)
      refute Retry.retryable_status?(Retry.new(statuses: []), 503)
    end

    test "transport and HTTP client errors follow retry_transport_errors" do
      exceptions = [
        %Req.TransportError{reason: :econnrefused},
        %Req.TransportError{reason: :closed},
        %Req.TransportError{reason: :timeout},
        %Req.TransportError{reason: :nxdomain},
        %Req.HTTPError{protocol: :http2, reason: :unprocessed}
      ]

      for exception <- exceptions do
        assert Retry.retryable?(%Retry{}, exception)
        refute Retry.retryable?(Retry.new(retry_transport_errors: false), exception)
      end
    end

    test "other exceptions are never retried" do
      refute Retry.retryable?(%Retry{}, %RuntimeError{message: "boom"})
      refute Retry.retryable?(%Retry{}, %Req.DecompressError{format: :gzip, data: ""})
    end
  end

  describe "delay/2" do
    test "doubles from backoff_initial_ms up to backoff_max_ms" do
      assert Enum.map(0..5, &Retry.delay(Retry.new(jitter: 0), &1)) == [500, 1_000, 2_000, 4_000, 5_000, 5_000]

      policy = Retry.new(backoff_initial_ms: 100, backoff_max_ms: 250, jitter: 0)
      assert Enum.map(0..3, &Retry.delay(policy, &1)) == [100, 200, 250, 250]
    end

    test "zero backoff settings disable the delay" do
      assert Retry.delay(Retry.new(backoff_initial_ms: 0), 3) == 0
      assert Retry.delay(Retry.new(backoff_max_ms: 0), 3) == 0
    end

    test "jitter subtracts at most its fraction of the delay" do
      policy = Retry.new(backoff_initial_ms: 1_000, backoff_max_ms: 8_000, jitter: 0.25)

      for retry_count <- 0..3, _sample <- 1..50 do
        base = min(1_000 * Integer.pow(2, retry_count), 8_000)
        delay = Retry.delay(policy, retry_count)

        assert delay >= round(base * 0.75) and delay <= base
      end
    end

    test "full jitter keeps delays between 0 and the backoff" do
      policy = Retry.new(backoff_initial_ms: 400, jitter: 1)

      for _sample <- 1..50, do: assert(Retry.delay(policy, 0) in 0..400)
    end

    test "a very large retry count stays at backoff_max_ms" do
      assert Retry.delay(Retry.new(jitter: 0), 10_000) == 5_000
    end
  end

  describe "parse_retry_after/2" do
    @now ~U[2026-09-16 12:00:00Z]

    test "reads retry-after-ms in milliseconds" do
      assert Retry.parse_retry_after(%{"retry-after-ms" => ["1500"]}) == 1_500
      assert Retry.parse_retry_after(%{"retry-after-ms" => ["12.4"]}) == 12
      assert Retry.parse_retry_after(%{"retry-after-ms" => [" 250 "]}) == 250
      assert Retry.parse_retry_after(%{"retry-after-ms" => ["0"]}) == 0
    end

    test "reads Retry-After in seconds" do
      assert Retry.parse_retry_after(%{"retry-after" => ["2"]}) == 2_000
      assert Retry.parse_retry_after(%{"retry-after" => ["0.5"]}) == 500
      assert Retry.parse_retry_after(%{"retry-after" => "4"}) == 4_000
    end

    test "retry-after-ms wins over Retry-After, and an invalid one falls back to it" do
      assert Retry.parse_retry_after(%{"retry-after-ms" => ["250"], "retry-after" => ["10"]}) == 250
      assert Retry.parse_retry_after(%{"retry-after-ms" => ["soon"], "retry-after" => ["3"]}) == 3_000
    end

    test "uses the first value of a repeated header" do
      assert Retry.parse_retry_after(%{"retry-after" => ["1", "9"]}) == 1_000
    end

    test "reads Retry-After as an HTTP date relative to now" do
      assert Retry.parse_retry_after(%{"retry-after" => ["Wed, 16 Sep 2026 12:00:30 GMT"]}, @now) == 30_000
      assert Retry.parse_retry_after(%{"retry-after" => ["Thu, 17 Sep 2026 12:00:00 GMT"]}, @now) == 86_400_000
    end

    test "a past HTTP date means no wait" do
      assert Retry.parse_retry_after(%{"retry-after" => ["Tue, 15 Sep 2026 12:00:00 GMT"]}, @now) == 0
    end

    test "returns nil for missing, negative or malformed values" do
      for headers <- [
            %{},
            %{"retry-after-ms" => ["-1"]},
            %{"retry-after" => ["-2"]},
            %{"retry-after" => ["soon"]},
            %{"retry-after" => [""]},
            %{"retry-after" => ["1 second"]},
            %{"retry-after" => []},
            %{"retry-after" => ["16 Sep 2026 12:00:30 GMT"]},
            %{"retry-after" => ["Wed, 31 Feb 2026 12:00:00 GMT"]},
            %{"retry-after" => ["Wed, 16 Foo 2026 12:00:00 GMT"]},
            %{"retry-after" => ["Wed, 16 Sep 2026 25:00:00 GMT"]},
            %{"retry-after" => ["Wed, 16 Sep 2026 12:00:00 UTC"]}
          ] do
        assert Retry.parse_retry_after(headers, @now) == nil, "expected nil for #{inspect(headers)}"
      end
    end

    test "returns nil for headers that are not a map" do
      assert Retry.parse_retry_after([{"retry-after", "1"}]) == nil
      assert Retry.parse_retry_after(nil) == nil
    end

    test "accepts a leading decimal point" do
      assert Retry.parse_retry_after(%{"retry-after" => [".5"]}) == 500
      assert Retry.parse_retry_after(%{"retry-after-ms" => [".4"]}) == 0
      assert Retry.parse_retry_after(%{"retry-after" => ["-.5"]}) == nil
      assert Retry.parse_retry_after(%{"retry-after" => ["."]}) == nil
    end

    test "caps huge delays at one year instead of overflowing" do
      year_ms = 31_536_000_000

      assert Retry.parse_retry_after(%{"retry-after" => ["1e308"]}) == year_ms
      assert Retry.parse_retry_after(%{"retry-after-ms" => ["1e308"]}) == year_ms
      assert Retry.parse_retry_after(%{"retry-after" => ["99999999999999999999999"]}) == year_ms
      assert Retry.parse_retry_after(%{"retry-after" => ["31536000"]}) == year_ms
      assert Retry.parse_retry_after(%{"retry-after" => ["31536001"]}) == year_ms
      assert Retry.parse_retry_after(%{"retry-after" => ["Mon, 01 Jan 2999 00:00:00 GMT"]}, @now) == year_ms
    end

    test "ignores values that are not finite numbers" do
      for value <- ["1e400", "Infinity", "NaN", "inf", "1e99999999999999999"] do
        assert Retry.parse_retry_after(%{"retry-after-ms" => [value]}) == nil
        assert Retry.parse_retry_after(%{"retry-after" => [value]}) == nil
      end

      assert Retry.parse_retry_after(%{"retry-after-ms" => ["1e400"], "retry-after" => ["2"]}) == 2_000
    end

    test "reads the obsolete RFC 850 and asctime date formats" do
      assert Retry.parse_retry_after(%{"retry-after" => ["Wednesday, 16-Sep-26 12:00:30 GMT"]}, @now) == 30_000
      assert Retry.parse_retry_after(%{"retry-after" => ["Wed Sep 16 12:00:30 2026"]}, @now) == 30_000
      assert Retry.parse_retry_after(%{"retry-after" => ["Thu Sep  17 12:00:00 2026"]}, @now) == 86_400_000
      assert Retry.parse_retry_after(%{"retry-after" => ["Thu Sep 17 12:00:00 2026"]}, @now) == 86_400_000
      assert Retry.parse_retry_after(%{"retry-after" => ["Sun Nov  6 08:49:37 1994"]}, @now) == 0
      assert Retry.parse_retry_after(%{"retry-after" => ["Sunday, 06-Nov-94 08:49:37 GMT"]}, @now) == 0
    end

    test "an RFC 850 year more than 50 years ahead is in the past" do
      assert Retry.parse_retry_after(%{"retry-after" => ["Monday, 01-Jan-76 00:00:00 GMT"]}, @now) == 31_536_000_000
      assert Retry.parse_retry_after(%{"retry-after" => ["Tuesday, 01-Jan-77 00:00:00 GMT"]}, @now) == 0
    end

    test "rejects malformed obsolete dates" do
      for value <- [
            "Wednesday, 16-Sep-2026 12:00:30 GMT",
            "Wednesday, 16-Foo-26 12:00:30 GMT",
            "Wednesday, 31-Feb-26 12:00:30 GMT",
            "Wed Sep 16 12:00:30 26",
            "Wed Sep 16 25:00:30 2026",
            "Wed Sep 16 12:00:30 2026 GMT"
          ] do
        assert Retry.parse_retry_after(%{"retry-after" => [value]}, @now) == nil, "expected nil for #{inspect(value)}"
      end
    end

    property "never raises and returns nil or a delay of at most one year, whatever the header values" do
      check all ms <- header_value(), seconds <- header_value(), max_runs: 500 do
        for headers <- [%{"retry-after-ms" => [ms], "retry-after" => [seconds]}, %{"retry-after" => seconds}] do
          result = Retry.parse_retry_after(headers, @now)
          assert is_nil(result) or (is_integer(result) and result in 0..31_536_000_000)
        end
      end
    end

    property "numeric values scale to milliseconds or clamp to one year" do
      check all number <- one_of([float(min: 0.0), integer(0..1_000_000_000_000)]) do
        text = to_string(number)
        expected = min(round(number * 1000), 31_536_000_000)
        assert Retry.parse_retry_after(%{"retry-after" => [text]}) == expected
      end
    end
  end

  describe "decide/3" do
    setup do
      %{policy: Retry.new(backoff_initial_ms: 100, jitter: 0), request: Req.new()}
    end

    test "returns a backoff delay for a retryable status", %{policy: policy, request: request} do
      assert Retry.decide(policy, request, Req.Response.new(status: 503)) == {:delay, 100}

      request = Req.Request.put_private(request, :req_retry_count, 2)
      assert Retry.decide(policy, request, Req.Response.new(status: 503)) == {:delay, 400}
    end

    test "returns false for a status that is not retryable", %{policy: policy, request: request} do
      for status <- [400, 401, 403, 404, 422] do
        response = Req.Response.new(status: status, headers: %{"retry-after-ms" => "10"})
        assert Retry.decide(policy, request, response) == false
      end
    end

    test "honours retry-after-ms and Retry-After", %{policy: policy, request: request} do
      assert Retry.decide(policy, request, response(429, %{"retry-after-ms" => "1234"})) == {:delay, 1_234}
      assert Retry.decide(policy, request, response(529, %{"retry-after" => "3"})) == {:delay, 3_000}
      assert Retry.decide(policy, request, response(503, %{"retry-after" => "0"})) == {:delay, 0}
    end

    test "ignores the header when respect_retry_after is false", %{request: request} do
      policy = Retry.new(backoff_initial_ms: 100, jitter: 0, respect_retry_after: false)

      assert Retry.decide(policy, request, response(429, %{"retry-after-ms" => "1234"})) == {:delay, 100}
    end

    test "falls back to backoff when the header exceeds max_retry_after_ms", %{request: request} do
      policy = Retry.new(backoff_initial_ms: 100, jitter: 0, max_retry_after_ms: 2_000)

      assert Retry.decide(policy, request, response(429, %{"retry-after-ms" => "2000"})) == {:delay, 2_000}
      assert Retry.decide(policy, request, response(429, %{"retry-after-ms" => "2001"})) == {:delay, 100}
      assert Retry.decide(policy, request, response(429, %{"retry-after" => "3600"})) == {:delay, 100}
    end

    test "falls back to backoff when the header is invalid", %{policy: policy, request: request} do
      assert Retry.decide(policy, request, response(429, %{"retry-after" => "later"})) == {:delay, 100}
    end

    test "retries transport errors with backoff unless disabled", %{policy: policy, request: request} do
      assert Retry.decide(policy, request, %Req.TransportError{reason: :econnrefused}) == {:delay, 100}

      assert Retry.decide(%{policy | retry_transport_errors: false}, request, %Req.TransportError{reason: :closed}) ==
               false

      assert Retry.decide(policy, request, %RuntimeError{message: "boom"}) == false
    end

    test "stops when elapsed time plus the next delay reaches the budget", %{request: request} do
      policy = Retry.new(backoff_initial_ms: 100, jitter: 0, budget_ms: 1_000)
      now = System.monotonic_time(:millisecond)

      recent = Req.Request.put_private(request, :typesafe_started_at, now - 100)
      assert Retry.decide(policy, recent, Req.Response.new(status: 503)) == {:delay, 100}

      spent = Req.Request.put_private(request, :typesafe_started_at, now - 900)
      assert Retry.decide(policy, spent, Req.Response.new(status: 503)) == false
      assert Retry.decide(policy, recent, response(429, %{"retry-after-ms" => "950"})) == false
    end

    test "ignores the budget without a start stamp or with budget_ms: nil", %{request: request} do
      stale = Req.Request.put_private(request, :typesafe_started_at, System.monotonic_time(:millisecond) - 60_000)

      assert Retry.decide(Retry.new(backoff_initial_ms: 100, jitter: 0), request, Req.Response.new(status: 503)) ==
               {:delay, 100}

      assert Retry.decide(
               Retry.new(backoff_initial_ms: 100, jitter: 0, budget_ms: nil),
               stale,
               Req.Response.new(status: 503)
             ) ==
               {:delay, 100}
    end

    test "never returns true, which Req would pair with its own delay", %{request: request} do
      outcomes = [
        Req.Response.new(status: 200),
        Req.Response.new(status: 429),
        response(429, %{"retry-after" => "1"}),
        Req.Response.new(status: 503),
        %Req.TransportError{reason: :timeout},
        %RuntimeError{message: "boom"}
      ]

      for outcome <- outcomes, policy <- [%Retry{}, Retry.new(respect_retry_after: false), Retry.new(budget_ms: 1)] do
        decision = Retry.decide(policy, request, outcome)
        assert decision == false or match?({:delay, ms} when is_integer(ms) and ms >= 0, decision)
      end
    end
  end

  describe "retrying requests" do
    test "429 then 200 succeeds, waiting for retry-after-ms" do
      Req.Test.expect(TypeSafe, &json(&1, 429, %{"error" => "rate limited"}, [{"retry-after-ms", "80"}]))
      Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))

      {elapsed, log} = timed_log(fn -> assert {:ok, %Response{}} = ask(client()) end)

      assert elapsed >= 80
      assert log =~ "retry: got response with status 429, will retry in 80ms, 2 attempts left"
      Req.Test.verify!(TypeSafe)
    end

    test "Retry-After in seconds replaces the backoff delay" do
      Req.Test.expect(TypeSafe, &json(&1, 503, %{"detail" => "Service Unavailable"}, [{"retry-after", "0"}]))
      Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))

      {elapsed, _log} =
        timed_log(fn -> assert {:ok, %Response{}} = ask(client(retry: [backoff_initial_ms: 10_000])) end)

      assert elapsed < 5_000
      Req.Test.verify!(TypeSafe)
    end

    for status <- [408, 429, 500, 502, 503, 504, 529] do
      test "HTTP #{status} is retried" do
        Req.Test.expect(TypeSafe, 2, &json(&1, unquote(status), %{"detail" => "try again"}))
        Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))

        assert {:ok, %Response{}} = ask(client())
        Req.Test.verify!(TypeSafe)
      end
    end

    for status <- [400, 401, 403, 404, 409, 422] do
      test "HTTP #{status} is not retried" do
        Req.Test.expect(TypeSafe, &json(&1, unquote(status), %{"detail" => "no"}))

        assert {:error, %Error{status: unquote(status)}} = ask(client())
        Req.Test.verify!(TypeSafe)
      end
    end

    for {reason, type} <- [econnrefused: :transport, closed: :transport, timeout: :timeout] do
      test "#{reason} transport errors are retried and then surfaced as :#{type}" do
        Req.Test.expect(TypeSafe, 3, &Req.Test.transport_error(&1, unquote(reason)))

        assert {:error, %Error{type: unquote(type), reason: unquote(reason), status: nil}} = ask(client())
        Req.Test.verify!(TypeSafe)
      end
    end

    test "a transport error followed by a success returns the success" do
      Req.Test.expect(TypeSafe, &Req.Test.transport_error(&1, :closed))
      Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))

      assert {:ok, %Response{request_id: "req_01a0ac5f3b2e4d6c8a9b"}} = ask(client())
      Req.Test.verify!(TypeSafe)
    end

    test "retry_transport_errors: false surfaces the first transport error" do
      Req.Test.expect(TypeSafe, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Error{type: :transport}} = ask(client(retry: Keyword.put(@fast, :retry_transport_errors, false)))
      Req.Test.verify!(TypeSafe)
    end

    test "the default max_retries makes three attempts in total" do
      Req.Test.expect(TypeSafe, 3, &json(&1, 503, %{"detail" => "Service Unavailable"}))

      assert {:error, %Error{type: :server, status: 503}} = ask(client())
      Req.Test.verify!(TypeSafe)
    end

    test "max_retries sets the number of retries after the first attempt" do
      Req.Test.expect(TypeSafe, &json(&1, 529, %{"detail" => "Overloaded"}))
      assert {:error, %Error{type: :overloaded}} = ask(client(retry: Keyword.put(@fast, :max_retries, 0)))
      Req.Test.verify!(TypeSafe)

      Req.Test.expect(TypeSafe, 5, &json(&1, 529, %{"detail" => "Overloaded"}))
      assert {:error, %Error{type: :overloaded}} = ask(client(retry: Keyword.put(@fast, :max_retries, 4)))
      Req.Test.verify!(TypeSafe)
    end

    test "custom statuses replace the default list" do
      policy = Keyword.put(@fast, :statuses, [409])

      Req.Test.expect(TypeSafe, &json(&1, 409, %{"detail" => "Conflict"}))
      Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))
      assert {:ok, %Response{}} = ask(client(retry: policy))

      Req.Test.expect(TypeSafe, &json(&1, 503, %{"detail" => "Service Unavailable"}))
      assert {:error, %Error{status: 503}} = ask(client(retry: policy))
      Req.Test.verify!(TypeSafe)
    end

    test "the error after retries describes the final attempt" do
      Req.Test.expect(TypeSafe, &json(&1, 503, %{"detail" => "first"}, [{"x-typesafe-request-id", "req_first"}]))
      Req.Test.expect(TypeSafe, &json(&1, 529, %{"detail" => "second"}, [{"x-typesafe-request-id", "req_second"}]))
      Req.Test.expect(TypeSafe, &json(&1, 500, %{"detail" => "final"}, [{"x-typesafe-request-id", "req_final"}]))

      assert {:error, %Error{type: :server, status: 500, message: "final", request_id: "req_final"}} = ask(client())
      Req.Test.verify!(TypeSafe)
    end

    test "a Retry-After above max_retry_after_ms falls back to backoff" do
      headers = [{"retry-after-ms", "120000"}, {"retry-after", "120"}]
      Req.Test.expect(TypeSafe, &json(&1, 429, %{"detail" => "Too Many Requests"}, headers))
      Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))

      {elapsed, log} =
        timed_log(fn ->
          assert {:ok, %Response{}} = ask(client(retry: Keyword.put(@fast, :max_retry_after_ms, 1_000)))
        end)

      assert elapsed < 1_000
      assert log =~ "will retry in 0ms"
      Req.Test.verify!(TypeSafe)
    end

    test "respect_retry_after: false ignores the server's delay" do
      Req.Test.expect(TypeSafe, &json(&1, 429, %{"detail" => "Too Many Requests"}, [{"retry-after-ms", "60000"}]))
      Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))

      {elapsed, _log} =
        timed_log(fn ->
          assert {:ok, %Response{}} = ask(client(retry: Keyword.put(@fast, :respect_retry_after, false)))
        end)

      assert elapsed < 1_000
      Req.Test.verify!(TypeSafe)
    end

    test "retries are logged at :debug only" do
      Req.Test.expect(TypeSafe, &json(&1, 503, %{"detail" => "Service Unavailable"}))
      Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))

      log = capture_log([level: :info], fn -> assert {:ok, %Response{}} = ask(client()) end)

      refute log =~ "retry: got response"
      Req.Test.verify!(TypeSafe)
    end
  end

  describe "budget" do
    test "an attempt that uses up the budget is not retried" do
      Req.Test.expect(TypeSafe, fn conn ->
        Process.sleep(60)
        json(conn, 503, %{"detail" => "Service Unavailable"})
      end)

      assert {:error, %Error{type: :server}} =
               ask(client(retry: [backoff_initial_ms: 0, budget_ms: 50, max_retries: 5]))

      Req.Test.verify!(TypeSafe)
    end

    test "stops before a fourth attempt once the budget would be exceeded" do
      Req.Test.expect(TypeSafe, 3, fn conn ->
        Process.sleep(150)
        json(conn, 503, %{"detail" => "Service Unavailable"})
      end)

      assert {:error, %Error{type: :server}} =
               ask(client(retry: [backoff_initial_ms: 0, budget_ms: 420, max_retries: 5]))

      Req.Test.verify!(TypeSafe)
    end

    test "a backoff longer than the budget returns the error without waiting" do
      Req.Test.expect(TypeSafe, &json(&1, 503, %{"detail" => "Service Unavailable"}))

      {elapsed, _log} =
        timed_log(fn ->
          assert {:error, %Error{status: 503}} =
                   ask(client(retry: [backoff_initial_ms: 1_000, jitter: 0, budget_ms: 500]))
        end)

      assert elapsed < 500
      Req.Test.verify!(TypeSafe)
    end

    test "a huge Retry-After falls back to backoff instead of raising" do
      Req.Test.expect(TypeSafe, &json(&1, 503, %{"detail" => "Service Unavailable"}, [{"retry-after", "1e308"}]))
      Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))

      assert {:ok, %Response{}} = ask(client())
      Req.Test.verify!(TypeSafe)
    end

    test "a huge Retry-After on a 429 without retries is reported, capped" do
      Req.Test.expect(TypeSafe, &json(&1, 429, %{"detail" => "slow"}, [{"retry-after", "1e308"}]))

      assert {:error, %Error{type: :rate_limited, retry_after_ms: 31_536_000_000}} = ask(client(retry: false))
      Req.Test.verify!(TypeSafe)
    end

    test "a Retry-After longer than the budget returns :rate_limited with the server's delay" do
      Req.Test.expect(TypeSafe, &json(&1, 429, %{"detail" => "Too Many Requests"}, [{"retry-after-ms", "5000"}]))

      {elapsed, _log} =
        timed_log(fn ->
          assert {:error, %Error{type: :rate_limited, retry_after_ms: 5_000}} =
                   ask(client(retry: [backoff_initial_ms: 0, budget_ms: 1_000]))
        end)

      assert elapsed < 1_000
      Req.Test.verify!(TypeSafe)
    end
  end

  describe "disabling retries" do
    test "retry: false on the client makes one attempt" do
      Req.Test.expect(TypeSafe, &json(&1, 503, %{"detail" => "Service Unavailable"}))

      assert {:error, %Error{type: :server}} = ask(client(retry: false))
      Req.Test.verify!(TypeSafe)
    end

    test "retry: false on a call overrides the client's policy" do
      Req.Test.expect(TypeSafe, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Error{type: :transport}} = ask(client(), retry: false)
      Req.Test.verify!(TypeSafe)
    end

    test "a per-call policy enables retries on a client without them" do
      Req.Test.expect(TypeSafe, &json(&1, 503, %{"detail" => "Service Unavailable"}))
      Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))

      assert {:ok, %Response{}} = ask(client(retry: false), retry: %Retry{backoff_initial_ms: 0, max_retries: 1})
      Req.Test.verify!(TypeSafe)
    end
  end

  describe "x-typesafe-retry-count" do
    test "is absent on the first attempt and counts retries after it" do
      test_pid = self()
      Req.Test.expect(TypeSafe, 2, reporting(test_pid, &json(&1, 503, %{"detail" => "Service Unavailable"})))
      Req.Test.expect(TypeSafe, reporting(test_pid, &json(&1, 200, noul_body())))

      assert {:ok, %Response{}} = ask(client())

      assert Enum.map(receive_requests(), & &1.headers["x-typesafe-retry-count"]) == [nil, ["1"], ["2"]]
    end

    test "is sent on retries after transport errors" do
      test_pid = self()
      Req.Test.expect(TypeSafe, 3, reporting(test_pid, &Req.Test.transport_error(&1, :timeout)))

      assert {:error, %Error{type: :timeout}} = ask(client())

      assert Enum.map(receive_requests(), & &1.headers["x-typesafe-retry-count"]) == [nil, ["1"], ["2"]]
    end

    test "starts over on the next call with the same client" do
      test_pid = self()
      client = client()
      Req.Test.expect(TypeSafe, reporting(test_pid, &json(&1, 503, %{"detail" => "Service Unavailable"})))
      Req.Test.expect(TypeSafe, 2, reporting(test_pid, &json(&1, 200, noul_body())))

      assert {:ok, %Response{}} = ask(client)
      assert {:ok, %Response{}} = ask(client)

      assert Enum.map(receive_requests(), & &1.headers["x-typesafe-retry-count"]) == [nil, ["1"], nil]
    end

    test "every attempt carries the identification headers" do
      test_pid = self()
      Req.Test.expect(TypeSafe, reporting(test_pid, &json(&1, 529, %{"detail" => "Overloaded"})))
      Req.Test.expect(TypeSafe, reporting(test_pid, &json(&1, 200, noul_body())))

      assert {:ok, %Response{}} = ask(client(headers: %{"x-team" => "support"}))

      for request <- receive_requests() do
        assert request.headers["authorization"] == ["Bearer ts_test_key"]
        assert request.headers["x-typesafe-sdk"] == [TypeSafe.Client.sdk()]
        assert request.headers["x-team"] == ["support"]

        assert request.json["questions"] == %{
                 "is_urgent" => %{"type" => "noul", "instructions" => "Does this convey urgency?"}
               }
      end
    end
  end

  defp ask(client, opts \\ []), do: TypeSafe.ask(client, "state", noul_question(), opts)

  # Header values: arbitrary text and bytes, plus near-misses of numbers and HTTP dates.
  defp header_value do
    one_of([
      string(:printable),
      binary(),
      map(float(), &Float.to_string/1),
      map(integer(), &Integer.to_string/1),
      map({string(:alphanumeric), string([?0..?9, ?., ?e, ?E, ?-, ?+, ?\s], max_length: 400)}, fn {a, b} -> a <> b end),
      map(string([?0..?9, ?., ?e, ?-, ?+], max_length: 400), & &1),
      map({member_of(["Mon", "Sunday", "Tue"]), integer(-5..99), string(:printable, max_length: 30)}, fn
        {day, n, rest} -> "#{day}, #{n}-Nov-94 #{rest}"
      end),
      map(integer(0..3000), &"Sun Nov  6 08:49:37 #{&1}"),
      map(integer(0..9999), &"Sun, 06 Nov #{&1} 08:49:37 GMT")
    ])
  end

  defp response(status, headers), do: Req.Response.new(status: status, headers: headers)

  defp timed_log(fun) do
    started = System.monotonic_time(:millisecond)
    log = capture_log([level: :debug], fun)
    {System.monotonic_time(:millisecond) - started, log}
  end
end
