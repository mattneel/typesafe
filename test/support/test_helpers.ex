defmodule TypeSafe.TestHelpers do
  @moduledoc false

  # Shared helpers for the package's own tests. Every client built here routes through
  # `Req.Test` under the `TypeSafe` stub name, so no test touches the network.

  @fixtures Path.expand("../fixtures", __DIR__)

  @doc "Builds a client wired to `Req.Test` with instant retries and no budget."
  def client(opts \\ []) do
    defaults = [
      api_key: "ts_test_key",
      base_url: "https://api.typesafe.ai",
      model: "jev-latest",
      retry: [backoff_initial_ms: 0, budget_ms: nil],
      req_options: [plug: {Req.Test, TypeSafe}]
    ]

    TypeSafe.new(Keyword.merge(defaults, opts))
  end

  @doc "Reads and decodes a JSON fixture, such as `fixture(\"responses/choice.json\")`."
  def fixture(path), do: path |> fixture_raw() |> JSON.decode!()

  @doc "Reads a fixture file as a binary."
  def fixture_raw(path), do: File.read!(Path.join(@fixtures, path))

  @doc "Returns the absolute path of a fixture."
  def fixture_path(path), do: Path.join(@fixtures, path)

  @doc "Decodes the JSON body a plug received."
  def request_json(conn), do: conn |> Req.Test.raw_body() |> IO.iodata_to_binary() |> JSON.decode!()

  @doc "Sends a JSON response from a plug."
  def send_json(conn, status, body, headers \\ []) do
    conn
    |> then(&Enum.reduce(headers, &1, fn {name, value}, conn -> Plug.Conn.put_resp_header(conn, name, value) end))
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end
end
