defmodule TypeSafe.Retry do
  # Each option is defined once: the keyword schema validates options, the struct schema
  # generates `t()`, and parsing an empty list yields the struct defaults.
  @fields [
    max_retries:
      [description: "Retries after the first attempt; `0` disables retries.", typespec: quote(do: non_neg_integer())]
      |> Zoi.integer()
      |> Zoi.gte(0)
      |> Zoi.default(2),
    backoff_initial_ms:
      [
        description: "First backoff delay in milliseconds, doubled on each retry; `0` disables backoff.",
        typespec: quote(do: non_neg_integer())
      ]
      |> Zoi.integer()
      |> Zoi.gte(0)
      |> Zoi.default(500),
    backoff_max_ms:
      [
        description: "Upper bound for a single backoff delay in milliseconds.",
        typespec: quote(do: non_neg_integer())
      ]
      |> Zoi.integer()
      |> Zoi.gte(0)
      |> Zoi.default(5_000),
    jitter:
      [description: "Fraction of each backoff delay randomly subtracted, from 0 to 1."]
      |> Zoi.number()
      |> Zoi.gte(0)
      |> Zoi.lte(1)
      |> Zoi.default(0.25),
    statuses:
      Zoi.any()
      |> Zoi.list(
        description: "HTTP statuses that are retried, as integers or ranges such as `500..599`.",
        typespec: quote(do: [pos_integer() | Range.t()])
      )
      |> Zoi.refine({TypeSafe.Retry, :validate_statuses, []})
      |> Zoi.default([408, 429, 500..599]),
    respect_retry_after:
      [description: "Whether to wait for the `retry-after-ms` or `Retry-After` header when present."]
      |> Zoi.boolean()
      |> Zoi.default(true),
    max_retry_after_ms:
      [
        description:
          "Longest server-requested delay to honour; longer values fall back to backoff, as in the JavaScript SDK.",
        typespec: quote(do: non_neg_integer())
      ]
      |> Zoi.integer()
      |> Zoi.gte(0)
      |> Zoi.default(60_000),
    retry_transport_errors:
      [description: "Whether to retry connection failures and timeouts."]
      |> Zoi.boolean()
      |> Zoi.default(true),
    budget_ms:
      [
        description:
          "Total time budget per call in milliseconds, including the first attempt and every delay; `nil` disables it.",
        typespec: quote(do: pos_integer() | nil)
      ]
      |> Zoi.integer()
      |> Zoi.positive()
      |> Zoi.nullable()
      |> Zoi.default(30_000)
  ]

  @schema Zoi.keyword(@fields, unrecognized_keys: :error)

  @moduledoc """
  Retry policy for TypeSafe calls, mirroring the `RetryPolicy` of TypeSafe's official Python and
  JavaScript SDKs.

  The defaults match the Python and JavaScript SDKs, so a TypeSafe call behaves the same in
  every language: two retries after the first attempt, exponential backoff from 500 ms to a
  5 s cap with 25% jitter, retries on 408, 429 and every 5xx (including 529 Overloaded) plus
  connection failures and timeouts, `Retry-After` honoured, and a 30 s budget for the whole call.

  Only transient failures are retried. The System One endpoint has no side effects, which is
  what makes retrying a `POST` safe. Req's built-in `:safe_transient` mode only retries `GET`
  and `HEAD`, so the policy compiles into a `retry:` function instead.

  ## Usage

      # Defaults
      TypeSafe.new(api_key: key)

      # A client with more patience
      TypeSafe.new(api_key: key, retry: [max_retries: 4, budget_ms: 60_000])

      # No retries for one call
      TypeSafe.ask(client, state, questions, retry: false)

  ## Options

  #{Zoi.describe(@schema)}

  ## Budget

  Before each retry, the policy compares the time since the call started plus the next delay
  with `budget_ms`. When the sum would reach the budget, it stops and the last error is
  returned. The start time lives in the request's private data, so no timer process is involved.
  """

  {:ok, defaults} = Zoi.parse(@schema, [])
  defstruct defaults

  @type t :: unquote(Zoi.type_spec(Zoi.struct(__MODULE__, Map.new(@fields))))

  @started_at_key :typesafe_started_at

  # One year: the longest delay parse_retry_after/2 reports, so absurd values cannot overflow.
  @max_delay_ms 31_536_000_000

  @doc """
  Builds a policy from options, validating each one.

  Accepts a keyword list or a policy struct. A struct is validated too, so a hand-built
  `%TypeSafe.Retry{jitter: 3}` is rejected. Raises `ArgumentError` when an option is unknown or
  out of range, or when the argument is neither a keyword list nor a policy.

      iex> TypeSafe.Retry.new(max_retries: 5).max_retries
      5
      iex> TypeSafe.Retry.new().budget_ms
      30000
      iex> TypeSafe.Retry.new(%TypeSafe.Retry{max_retries: 1}).max_retries
      1
  """
  @spec new(keyword() | t()) :: t()
  def new(opts \\ [])

  def new(%__MODULE__{} = policy), do: policy |> to_options() |> new()

  def new(opts) when is_list(opts) do
    if !Keyword.keyword?(opts),
      do: raise(ArgumentError, "invalid TypeSafe.Retry options: expected a keyword list, got: #{inspect(opts)}")

    case Zoi.parse(@schema, opts) do
      {:ok, parsed} ->
        # Zoi fills defaults for nil values, but an explicit `budget_ms: nil` disables the budget.
        parsed =
          if Keyword.fetch(opts, :budget_ms) == {:ok, nil}, do: Keyword.put(parsed, :budget_ms, nil), else: parsed

        struct!(__MODULE__, parsed)

      {:error, errors} ->
        raise ArgumentError, "invalid TypeSafe.Retry options: " <> Zoi.prettify_errors(errors)
    end
  end

  def new(other) do
    raise ArgumentError,
          "invalid TypeSafe.Retry options: expected a keyword list or a %TypeSafe.Retry{}, got: #{inspect(other)}"
  end

  @doc false
  # Merges retry options over a base policy, or over the defaults when the base is `false`.
  @spec merge(t() | false, keyword()) :: t()
  def merge(false, opts), do: new(opts)
  def merge(%__MODULE__{} = policy, opts), do: policy |> to_options() |> Keyword.merge(opts) |> new()

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Decides whether Req should retry, returning `{:delay, ms}` or `false`.

  This is the function the policy compiles into Req's `retry:` option. It returns `false` when
  the response or exception is not retryable or when the next delay would exhaust the budget.
  Otherwise it returns the delay: the server's `retry-after-ms` or `Retry-After` value when the
  policy honours it, or exponential backoff with jitter.

      iex> policy = TypeSafe.Retry.new(backoff_initial_ms: 100, jitter: 0)
      iex> request = Req.new()
      iex> TypeSafe.Retry.decide(policy, request, Req.Response.new(status: 503))
      {:delay, 100}
      iex> TypeSafe.Retry.decide(policy, request, Req.Response.new(status: 401))
      false
  """
  @spec decide(t(), Req.Request.t(), Req.Response.t() | Exception.t()) :: {:delay, non_neg_integer()} | false
  def decide(%__MODULE__{} = policy, %Req.Request{} = request, response_or_exception) do
    if retryable?(policy, response_or_exception) do
      retry_count = Req.Request.get_private(request, :req_retry_count, 0)
      delay = next_delay(policy, response_or_exception, retry_count)

      if within_budget?(policy, request, delay), do: {:delay, delay}, else: false
    else
      false
    end
  end

  @doc """
  Returns `true` when the policy retries this response or exception, ignoring counts and budget.

      iex> TypeSafe.Retry.retryable?(%TypeSafe.Retry{}, Req.Response.new(status: 529))
      true
      iex> TypeSafe.Retry.retryable?(%TypeSafe.Retry{}, %Req.TransportError{reason: :econnrefused})
      true
      iex> TypeSafe.Retry.retryable?(%TypeSafe.Retry{}, Req.Response.new(status: 422))
      false
  """
  @spec retryable?(t(), Req.Response.t() | Exception.t()) :: boolean()
  def retryable?(%__MODULE__{} = policy, %Req.Response{status: status}), do: retryable_status?(policy, status)

  def retryable?(%__MODULE__{retry_transport_errors: retry?}, %Req.TransportError{}), do: retry?
  def retryable?(%__MODULE__{retry_transport_errors: retry?}, %Req.HTTPError{}), do: retry?
  def retryable?(%__MODULE__{}, _other), do: false

  @doc """
  Returns `true` when `status` is one of the policy's retryable statuses.

      iex> TypeSafe.Retry.retryable_status?(%TypeSafe.Retry{}, 502)
      true
      iex> TypeSafe.Retry.retryable_status?(%TypeSafe.Retry{}, 404)
      false
  """
  @spec retryable_status?(t(), integer()) :: boolean()
  def retryable_status?(%__MODULE__{statuses: statuses}, status) when is_integer(status) do
    Enum.any?(statuses, fn
      %Range{} = range -> status in range
      code -> code == status
    end)
  end

  @doc """
  Returns the backoff delay in milliseconds before retry number `retry_count + 1`.

  The delay starts at `backoff_initial_ms`, doubles on each retry up to `backoff_max_ms`, and
  then has up to `jitter` of itself randomly subtracted.

      iex> policy = TypeSafe.Retry.new(jitter: 0)
      iex> Enum.map(0..4, &TypeSafe.Retry.delay(policy, &1))
      [500, 1000, 2000, 4000, 5000]
  """
  @spec delay(t(), non_neg_integer()) :: non_neg_integer()
  def delay(%__MODULE__{backoff_initial_ms: 0}, _retry_count), do: 0
  def delay(%__MODULE__{backoff_max_ms: 0}, _retry_count), do: 0

  def delay(%__MODULE__{} = policy, retry_count) when is_integer(retry_count) and retry_count >= 0 do
    # Cap the exponent so a large retry count cannot build a huge integer.
    exponential = min(policy.backoff_initial_ms * Integer.pow(2, min(retry_count, 32)), policy.backoff_max_ms)
    round(exponential * (1 - :rand.uniform() * policy.jitter))
  end

  @doc """
  Parses `retry-after-ms` or `Retry-After` from response headers into milliseconds.

  `retry-after-ms` wins when both are present. `Retry-After` may hold seconds (fractions such
  as `0.5` or `.5` are accepted) or an HTTP date in any of the three formats of RFC 9110:
  IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), RFC 850 (`Sunday, 06-Nov-94 08:49:37 GMT`) or
  asctime (`Sun Nov  6 08:49:37 1994`). A date in the past means no wait.

  Returns `nil` when neither header holds a valid, non-negative delay. Delays longer than one
  year are capped at one year (`31_536_000_000` ms). The function never raises, whatever the
  header values are.

      iex> TypeSafe.Retry.parse_retry_after(%{"retry-after-ms" => ["1500"]})
      1500
      iex> TypeSafe.Retry.parse_retry_after(%{"retry-after" => ["2"]})
      2000
      iex> TypeSafe.Retry.parse_retry_after(%{})
      nil
  """
  @spec parse_retry_after(map(), DateTime.t()) :: non_neg_integer() | nil
  def parse_retry_after(headers, now \\ DateTime.utc_now())

  def parse_retry_after(headers, now) when is_map(headers) do
    with nil <- headers |> header("retry-after-ms") |> parse_number(1) do
      case header(headers, "retry-after") do
        nil -> nil
        value -> parse_number(value, 1000) || parse_http_date(value, now)
      end
    end
  end

  def parse_retry_after(_headers, _now), do: nil

  @doc false
  # Req options for this policy (or for `false`, which disables retries).
  @spec req_options(t() | false) :: keyword()
  def req_options(false), do: [retry: false]

  def req_options(%__MODULE__{} = policy) do
    [
      retry: &decide(policy, &1, &2),
      max_retries: policy.max_retries,
      retry_log_level: :debug
    ]
  end

  @doc false
  @spec put_started_at(Req.Request.t()) :: Req.Request.t()
  def put_started_at(%Req.Request{} = request) do
    Req.Request.put_private(request, @started_at_key, System.monotonic_time(:millisecond))
  end

  @doc false
  @spec validate_statuses(list(), keyword()) :: :ok | {:error, String.t()}
  def validate_statuses(statuses, _opts) do
    if Enum.all?(statuses, &valid_status?/1),
      do: :ok,
      else: {:error, "expected HTTP status codes (100..599) or ranges of them"}
  end

  defp to_options(%__MODULE__{} = policy), do: policy |> Map.from_struct() |> Map.to_list()

  defp valid_status?(%Range{first: first, last: last}), do: is_integer(first) and first >= 100 and last <= 599
  defp valid_status?(status), do: is_integer(status) and status in 100..599

  defp next_delay(%__MODULE__{respect_retry_after: true} = policy, %Req.Response{headers: headers}, retry_count) do
    case parse_retry_after(headers) do
      ms when is_integer(ms) and ms <= policy.max_retry_after_ms -> ms
      _ -> delay(policy, retry_count)
    end
  end

  defp next_delay(policy, _response_or_exception, retry_count), do: delay(policy, retry_count)

  defp within_budget?(%__MODULE__{budget_ms: nil}, _request, _delay), do: true

  defp within_budget?(%__MODULE__{budget_ms: budget}, request, delay) do
    case Req.Request.get_private(request, @started_at_key) do
      started_at when is_integer(started_at) ->
        System.monotonic_time(:millisecond) - started_at + delay < budget

      _ ->
        true
    end
  end

  defp header(headers, name) do
    case Map.get(headers, name) do
      [value | _] when is_binary(value) -> String.trim(value)
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp parse_number(nil, _multiplier), do: nil

  # A delay above the cap (or one that would overflow when converted to milliseconds) is clamped
  # to it; values Float.parse/1 cannot represent, such as "1e400", are not a delay at all.
  defp parse_number("." <> _ = value, multiplier), do: parse_number("0" <> value, multiplier)

  defp parse_number(value, multiplier) do
    case Float.parse(value) do
      {number, ""} when number >= 0 and number <= @max_delay_ms / multiplier -> round(number * multiplier)
      {number, ""} when number > 0 -> @max_delay_ms
      _ -> nil
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp parse_http_date(value, now) do
    with {:ok, {year, month, day, hour, minute, second}} <- http_date_parts(value, now),
         index when is_integer(index) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, date} <- Date.new(year, index + 1, day),
         {:ok, time} <- Time.new(hour, minute, second),
         {:ok, datetime} <- DateTime.new(date, time) do
      datetime |> DateTime.diff(now, :millisecond) |> max(0) |> min(@max_delay_ms)
    else
      _ -> nil
    end
  end

  # The three HTTP-date formats of RFC 9110, section 5.6.7: IMF-fixdate, then the obsolete
  # RFC 850 and asctime formats, which recipients must still accept.
  defp http_date_parts(value, now) do
    Enum.find_value([:imf_fixdate, :rfc850, :asctime], :error, &http_date_parts(&1, value, now))
  end

  defp http_date_parts(:imf_fixdate, value, _now) do
    with [day, month, year, hour, minute, second] <-
           Regex.run(~r/^[A-Za-z]{3}, (\d{1,2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/, value,
             capture: :all_but_first
           ) do
      {:ok, {int(year), month, int(day), int(hour), int(minute), int(second)}}
    end
  end

  defp http_date_parts(:rfc850, value, now) do
    with [day, month, year, hour, minute, second] <-
           Regex.run(~r/^[A-Za-z]{6,9}, (\d{2})-([A-Za-z]{3})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) GMT$/, value,
             capture: :all_but_first
           ) do
      {:ok, {two_digit_year(int(year), now), month, int(day), int(hour), int(minute), int(second)}}
    end
  end

  defp http_date_parts(:asctime, value, _now) do
    with [month, day, hour, minute, second, year] <-
           Regex.run(~r/^[A-Za-z]{3} ([A-Za-z]{3}) {1,2}(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})$/, value,
             capture: :all_but_first
           ) do
      {:ok, {int(year), month, int(day), int(hour), int(minute), int(second)}}
    end
  end

  # RFC 9110: a two-digit year that appears more than 50 years in the future is in the past.
  defp two_digit_year(year, %DateTime{year: current}) do
    candidate = div(current, 100) * 100 + year
    if candidate > current + 50, do: candidate - 100, else: candidate
  end

  defp int(digits), do: String.to_integer(digits)
end
