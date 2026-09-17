defmodule TypeSafe.UsageTest do
  use ExUnit.Case, async: true

  alias TypeSafe.Usage

  describe "from_wire/1" do
    test "decodes both token counts" do
      assert Usage.from_wire(%{"input_tokens" => 312, "output_tokens" => 48}) ==
               {:ok, %Usage{input_tokens: 312, output_tokens: 48}}
    end

    test "leaves missing, null or absent counts as nil" do
      assert Usage.from_wire(nil) == {:ok, %Usage{}}
      assert Usage.from_wire(%{}) == {:ok, %Usage{input_tokens: nil, output_tokens: nil}}
      assert Usage.from_wire(%{"input_tokens" => 0, "output_tokens" => nil}) == {:ok, %Usage{input_tokens: 0}}
    end

    test "ignores counts it does not know" do
      assert Usage.from_wire(%{"input_tokens" => 1, "output_tokens" => 2, "cached_input_tokens" => 3}) ==
               {:ok, %Usage{input_tokens: 1, output_tokens: 2}}
    end

    test "rejects counts that are not non-negative integers" do
      for {value, code} <- [{-1, :greater_than_or_equal_to}, {1.5, :invalid_type}, {"312", :invalid_type}] do
        assert {:error, [%Zoi.Error{code: ^code, path: [:output_tokens]}]} =
                 Usage.from_wire(%{"output_tokens" => value})
      end
    end
  end
end
