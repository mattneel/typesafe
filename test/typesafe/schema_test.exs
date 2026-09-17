defmodule TypeSafe.SchemaTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Typesafe.Schema, as: SchemaTask
  alias TypeSafe.Schema

  # The task's default output, relative to the project root that `mix test` runs from.
  @schema_dir "priv/json_schema"
  @names ["models", "request", "response"]

  describe "json_schemas/0 contract" do
    test "generates the request, response and models documents" do
      assert Schema.json_schemas() |> Map.keys() |> Enum.sort() == @names
    end

    for name <- @names do
      test "matches the checked-in priv/json_schema/#{name}.json" do
        name = unquote(name)
        generated = Schema.json_schemas() |> Map.fetch!(name) |> TypeSafe.JSON.pretty()

        assert generated == File.read!(Path.join(@schema_dir, name <> ".json")),
               "priv/json_schema/#{name}.json is stale; run `mix typesafe.schema`"
      end
    end

    test "renders the same bytes on every call" do
      render = fn -> Map.new(Schema.json_schemas(), fn {name, doc} -> {name, TypeSafe.JSON.pretty(doc)} end) end

      assert render.() == render.()
    end

    test "sorts every required list" do
      for {_name, document} <- Schema.json_schemas(), required <- collect(document, :required) do
        assert required == Enum.sort_by(required, &to_string/1)
      end
    end

    test "describes the request envelope" do
      request = read_schema("request")

      assert %{
               "$schema" => "https://json-schema.org/draft/2020-12/schema",
               "title" => "SystemOneRequest",
               "required" => ["model", "questions", "state"]
             } = request

      assert %{"minProperties" => 1, "propertyNames" => %{"minLength" => 1}} = request["properties"]["questions"]

      assert Enum.map(request["properties"]["questions"]["additionalProperties"]["oneOf"], & &1["properties"]["type"]) ==
               [%{"const" => "noul"}, %{"const" => "choice"}, %{"const" => "score"}]
    end

    test "describes the response and models documents" do
      assert %{"title" => "SystemOneResponse", "required" => ["answers", "model"]} = read_schema("response")
      assert %{"title" => "ModelMetadataList", "required" => ["models"]} = read_schema("models")
    end
  end

  describe "mix typesafe.schema" do
    @describetag :tmp_dir

    test "writes every schema file to the output directory", %{tmp_dir: tmp_dir} do
      output = capture_io(fn -> assert SchemaTask.run(["--output", tmp_dir]) == :ok end)

      for name <- @names do
        path = Path.join(tmp_dir, name <> ".json")
        assert output =~ "Wrote #{path}"
        assert File.read!(path) == File.read!(Path.join(@schema_dir, name <> ".json"))
      end
    end

    test "--check passes on the checked-in files, which are the default output" do
      assert capture_io(fn -> SchemaTask.run(["--check"]) end) =~ "JSON Schemas in #{@schema_dir} are up to date"
    end

    test "--check passes on freshly written files", %{tmp_dir: tmp_dir} do
      capture_io(fn -> SchemaTask.run(["--output", tmp_dir]) end)

      assert capture_io(fn -> SchemaTask.run(["--check", "--output", tmp_dir]) end) =~ "are up to date"
    end

    test "--check raises and names a stale file", %{tmp_dir: tmp_dir} do
      capture_io(fn -> SchemaTask.run(["--output", tmp_dir]) end)
      stale = Path.join(tmp_dir, "response.json")
      File.write!(stale, "{}\n")

      error = assert_raise Mix.Error, fn -> capture_io(fn -> SchemaTask.run(["--check", "--output", tmp_dir]) end) end

      assert error.message ==
               "JSON Schemas are out of date: #{stale}. Run `mix typesafe.schema` to regenerate them."
    end

    test "--check raises for missing files without writing them", %{tmp_dir: tmp_dir} do
      error = assert_raise Mix.Error, fn -> capture_io(fn -> SchemaTask.run(["--check", "--output", tmp_dir]) end) end

      for name <- @names, do: assert(error.message =~ Path.join(tmp_dir, name <> ".json"))
      assert File.ls!(tmp_dir) == []
    end

    test "rejects unknown switches" do
      assert_raise OptionParser.ParseError, fn -> SchemaTask.run(["--force"]) end
    end
  end

  describe "pairs/1" do
    test "keeps list order and sorts maps by the string form of their keys" do
      assert Schema.pairs(b: 1, a: 2) == [b: 1, a: 2]
      assert Schema.pairs(%{"b" => 1, :a => 2, "C" => 3}) == [{"C", 3}, {:a, 2}, {"b", 1}]
    end

    test "sorts keys that are not atoms or strings after the rest" do
      assert Schema.pairs(%{1 => :int, "a" => :string}) == [{"a", :string}, {1, :int}]
    end
  end

  defp read_schema(name), do: [@schema_dir, name <> ".json"] |> Path.join() |> File.read!() |> JSON.decode!()

  defp collect(%{} = map, key) when not is_struct(map) do
    own = if is_list(map[key]), do: [map[key]], else: []
    own ++ Enum.flat_map(map, fn {_key, value} -> collect(value, key) end)
  end

  defp collect(list, key) when is_list(list), do: Enum.flat_map(list, &collect(&1, key))
  defp collect(_other, _key), do: []
end
