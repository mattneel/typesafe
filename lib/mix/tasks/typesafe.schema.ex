defmodule Mix.Tasks.Typesafe.Schema do
  @shortdoc "Writes the TypeSafe request and response JSON Schemas"

  @moduledoc """
  Writes JSON Schema documents for the TypeSafe wire format, generated from the SDK's Zoi
  schemas, for teams that validate payloads outside Elixir.

      $ mix typesafe.schema
      $ mix typesafe.schema --output schemas/typesafe
      $ mix typesafe.schema --check

  Files written:

    * `request.json` - the `POST /v1/systemone` request body.
    * `response.json` - the `POST /v1/systemone` response body.
    * `models.json` - the `GET /v1/models` response body.

  ## Options

    * `--output` - the directory to write to. Defaults to `priv/json_schema` in the current
      project.
    * `--check` - do not write; exit with a non-zero status when a file is missing or differs
      from the generated schema. Useful in CI.
  """

  use Mix.Task

  @switches [output: :string, check: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("compile")

    output = Keyword.get(opts, :output, Path.join("priv", "json_schema"))
    schemas = TypeSafe.Schema.json_schemas()

    if opts[:check] do
      check(schemas, output)
    else
      write(schemas, output)
    end
  end

  defp write(schemas, output) do
    File.mkdir_p!(output)

    for {name, schema} <- Enum.sort(schemas) do
      path = Path.join(output, name <> ".json")
      File.write!(path, TypeSafe.JSON.pretty(schema))
      Mix.shell().info("Wrote #{path}")
    end

    :ok
  end

  defp check(schemas, output) do
    stale =
      for {name, schema} <- Enum.sort(schemas),
          path = Path.join(output, name <> ".json"),
          File.read(path) != {:ok, TypeSafe.JSON.pretty(schema)},
          do: path

    case stale do
      [] ->
        Mix.shell().info("JSON Schemas in #{output} are up to date")

      paths ->
        Mix.raise(
          "JSON Schemas are out of date: #{Enum.join(paths, ", ")}. Run `mix typesafe.schema` to regenerate them."
        )
    end
  end
end
