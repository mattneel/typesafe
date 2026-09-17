defmodule TypeSafe.ModelTest do
  use ExUnit.Case, async: true

  import TypeSafe.TestHelpers

  alias TypeSafe.Model

  describe "from_wire/1" do
    test "decodes the recorded model list" do
      models = for raw <- fixture("responses/recorded_models.json")["models"], do: raw |> Model.from_wire() |> elem(1)

      assert [
               %Model{name: "jev-latest", release_date: "2026-09-10T18:38:01.391457+00:00"},
               %Model{name: "jev-preview"}
             ] = models

      assert Enum.all?(models, &(is_binary(&1.description) and &1.description != ""))
    end

    test "keeps the release date exactly as sent" do
      for release_date <- ["2026-09-10", "2026-09-10T18:38:01Z", "next week"] do
        assert {:ok, %Model{release_date: ^release_date}} =
                 Model.from_wire(%{"name" => "jev-latest", "description" => "Jev", "release_date" => release_date})
      end
    end

    test "ignores fields it does not know" do
      raw = %{
        "name" => "jev-latest",
        "description" => "Jev",
        "release_date" => "2026-09-10",
        "context_window" => 32_000
      }

      assert Model.from_wire(raw) == {:ok, %Model{name: "jev-latest", description: "Jev", release_date: "2026-09-10"}}
    end

    test "requires every field as a string" do
      assert {:error, errors} = Model.from_wire(%{"name" => "jev-latest"})

      assert errors |> Enum.map(&{&1.code, &1.path}) |> Enum.sort() == [
               required: [:description],
               required: [:release_date]
             ]

      assert {:error, [%Zoi.Error{code: :invalid_type, path: [:name]}]} =
               Model.from_wire(%{"name" => 1, "description" => "Jev", "release_date" => "2026-09-10"})
    end
  end
end
