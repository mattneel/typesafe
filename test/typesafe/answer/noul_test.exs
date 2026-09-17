defmodule TypeSafe.Answer.NoulTest do
  use ExUnit.Case, async: true

  import TypeSafe.TestHelpers

  alias TypeSafe.Answer.Noul

  describe "from_wire/1" do
    test "decodes the documented answer" do
      raw = fixture("responses/noul.json")["answers"]["is_urgent"]

      assert Noul.from_wire(raw) == {:ok, %Noul{noul: 0.92}}
    end

    test "returns integer probabilities as floats" do
      assert {:ok, %Noul{noul: one}} = Noul.from_wire(%{"type" => "noul", "noul" => 1})
      assert {:ok, %Noul{noul: zero}} = Noul.from_wire(%{"type" => "noul", "noul" => 0})

      assert {one, zero} === {1.0, 0.0}
    end

    test "ignores fields it does not know" do
      assert Noul.from_wire(%{"type" => "noul", "noul" => 0.4, "calibration" => "v2"}) == {:ok, %Noul{noul: 0.4}}
    end

    test "rejects probabilities outside 0..1" do
      assert {:error, [%Zoi.Error{code: :greater_than_or_equal_to, path: [:noul]}]} =
               Noul.from_wire(%{"type" => "noul", "noul" => -0.01})

      assert {:error, [%Zoi.Error{code: :less_than_or_equal_to, path: [:noul]}]} =
               Noul.from_wire(%{"type" => "noul", "noul" => 1.01})
    end

    test "rejects a probability that is not a number" do
      for value <- ["0.92", nil, true, [0.92]] do
        assert {:error, [%Zoi.Error{code: :invalid_type, path: [:noul]}]} =
                 Noul.from_wire(%{"type" => "noul", "noul" => value})
      end
    end

    test "requires the probability" do
      assert {:error, [%Zoi.Error{code: :required, path: [:noul]}]} = Noul.from_wire(%{"type" => "noul"})
    end
  end

  describe "yes?/2" do
    test "compares against 0.5 by default, inclusive" do
      assert Noul.yes?(%Noul{noul: 0.5})
      assert Noul.yes?(%Noul{noul: 0.92})
      refute Noul.yes?(%Noul{noul: 0.4999})
    end

    test "uses the caller's threshold, inclusive" do
      assert Noul.yes?(%Noul{noul: 0.9}, 0.9)
      refute Noul.yes?(%Noul{noul: 0.89}, 0.9)
      assert Noul.yes?(%Noul{noul: 0.3}, 0.25)
    end

    test "accepts integer thresholds at the ends of the range" do
      assert Noul.yes?(%Noul{noul: 0.0}, 0)
      assert Noul.yes?(%Noul{noul: 1.0}, 1)
      refute Noul.yes?(%Noul{noul: 0.99}, 1)
    end
  end
end
