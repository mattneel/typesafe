defmodule TypeSafe.TransportHelpers do
  @moduledoc false

  # Helpers for the transport-layer tests: capturing what a `Req.Test` plug received,
  # canned System One bodies shaped like the live API's, and attempt counting for retries.

  import ExUnit.Assertions

  @request_id "req_01a0ac5f3b2e4d6c8a9b"

  @doc "The request id used in canned responses."
  def request_id, do: @request_id

  @doc "The three canonical questions, keyed by atoms."
  def questions do
    %{
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
  end

  @doc "A single Noul question under `id`."
  def noul_question(id \\ :is_urgent), do: %{id => TypeSafe.noul("Does this convey urgency?")}

  @doc "A System One body answering `questions/0`, as the live API sends it."
  def systemone_body do
    %{
      "model" => "jev-1.13.0",
      "answers" => %{
        "is_urgent" => %{"type" => "noul", "noul" => 0.95},
        "department" => %{
          "type" => "choice",
          "choice" => "billing",
          "confidence" => 0.78,
          "probabilities" => %{"billing" => 0.86, "sales" => 0.0, "technical" => 0.14}
        },
        "frustration" => %{
          "type" => "score",
          "score" => 1.05,
          "confidence" => 0.93,
          "legend" => %{"0" => "Calm", "1" => "Frustrated", "2" => "Very angry"},
          "probabilities" => %{"0" => 0.0, "1" => 0.95, "2" => 0.05}
        }
      },
      "usage" => %{"input_tokens" => 414, "output_tokens" => 73}
    }
  end

  @doc "A System One body with one Noul answer under `id`."
  def noul_body(id \\ "is_urgent", noul \\ 0.95) do
    %{
      "model" => "jev-1.13.0",
      "answers" => %{id => %{"type" => "noul", "noul" => noul}},
      "usage" => %{"input_tokens" => 12, "output_tokens" => 3}
    }
  end

  @doc "A `GET /v1/models` body shaped like the live API's."
  def models_body do
    %{
      "models" => [
        %{
          "name" => "jev-latest",
          "description" => "The latest iteration of TypeSafe's System One Model: Jev",
          "release_date" => "2026-09-10T18:38:01.391457+00:00"
        },
        %{
          "name" => "jev-preview",
          "description" => "A preview version of `jev-latest`: should be better in most ways",
          "release_date" => "2026-09-10T18:39:06.057655+00:00"
        }
      ]
    }
  end

  @doc "Sends a JSON response with an `x-typesafe-request-id` header."
  def json(conn, status, body, headers \\ []) do
    TypeSafe.TestHelpers.send_json(conn, status, body, [{"x-typesafe-request-id", @request_id} | headers])
  end

  @doc "Sends a plain-text response."
  def text(conn, status, body, headers \\ []) do
    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> Plug.Conn.put_resp_header(conn, name, value) end)
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(status, body)
  end

  @doc """
  Stubs `name` (default `TypeSafe`) so every request is reported to the calling process as
  `{:typesafe_request, info}` before `respond` answers it.
  """
  def capture_requests(respond, name \\ TypeSafe) do
    test_pid = self()

    Req.Test.stub(name, fn conn ->
      send(test_pid, {:typesafe_request, request_info(conn)})
      respond.(conn)
    end)
  end

  @doc "Returns a plug that reports the request to `pid` and then calls `respond`."
  def reporting(pid, respond) do
    fn conn ->
      send(pid, {:typesafe_request, request_info(conn)})
      respond.(conn)
    end
  end

  @doc "Stubs `name` with a plug that fails the test if any request reaches the network."
  # The plug only ever raises (via flunk/1), which is the point.
  @dialyzer {:nowarn_function, refute_network: 0, refute_network: 1}
  def refute_network(name \\ TypeSafe) do
    Req.Test.stub(name, fn conn ->
      flunk("expected no HTTP request, got #{conn.method} #{conn.request_path}")
    end)
  end

  @doc "Receives the captured request, failing when none arrived."
  def receive_request do
    assert_received {:typesafe_request, info}
    info
  end

  @doc "Receives every captured request so far, in order."
  def receive_requests(acc \\ []) do
    receive do
      {:typesafe_request, info} -> receive_requests([info | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "The fields of a plug request that the tests assert on."
  def request_info(%Plug.Conn{} = conn) do
    raw = conn |> Req.Test.raw_body() |> IO.iodata_to_binary()

    %{
      method: conn.method,
      scheme: conn.scheme,
      host: conn.host,
      port: conn.port,
      path: conn.request_path,
      query: conn.query_string,
      headers: Enum.group_by(conn.req_headers, &elem(&1, 0), &elem(&1, 1)),
      raw_body: raw,
      json: decode_json(raw),
      private: conn.private[:req_private] || %{}
    }
  end

  @doc "A client wired to `Req.Test` that appends a request step reporting the final Req options."
  def reporting_options(client) do
    test_pid = self()

    step = fn request ->
      send(test_pid, {:typesafe_options, request.options})
      request
    end

    %{client | req: Req.Request.append_request_steps(client.req, report_options: step)}
  end

  @doc """
  Starts a minimal HTTP/1.1 server on a random local port, for the few tests that need a real
  Finch connection instead of `Req.Test`. Every request is answered with `status` and the JSON
  `body`. Returns the base URL; the server stops when the test exits.
  """
  def start_http_server(status, body) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    response = http_response(status, JSON.encode!(body))
    acceptor = spawn(fn -> accept_loop(listen, response) end)
    :ok = :gen_tcp.controlling_process(listen, acceptor)
    ExUnit.Callbacks.on_exit(fn -> Process.exit(acceptor, :kill) end)
    "http://127.0.0.1:#{port}"
  end

  defp http_response(status, body) do
    "HTTP/1.1 #{status} Status\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\n" <>
      "x-typesafe-request-id: #{@request_id}\r\n\r\n" <> body
  end

  defp accept_loop(listen, response) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        handler = spawn(fn -> serve(socket, response, "") end)
        :ok = :gen_tcp.controlling_process(socket, handler)
        accept_loop(listen, response)

      {:error, _reason} ->
        :ok
    end
  end

  defp serve(socket, response, buffer) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        buffer = buffer <> data

        if complete_request?(buffer) do
          :ok = :gen_tcp.send(socket, response)
          serve(socket, response, "")
        else
          serve(socket, response, buffer)
        end

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end
  end

  defp complete_request?(buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [head, body] ->
        case Regex.run(~r/content-length: *(\d+)/i, head) do
          [_, length] -> byte_size(body) >= String.to_integer(length)
          nil -> true
        end

      [_incomplete] ->
        false
    end
  end

  defp decode_json(""), do: nil

  defp decode_json(raw) do
    case JSON.decode(raw) do
      {:ok, decoded} -> decoded
      {:error, _} -> nil
    end
  end
end
