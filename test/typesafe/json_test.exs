defmodule TypeSafe.JSONTest do
  use ExUnit.Case, async: true

  import TypeSafe.WireHelpers

  alias TypeSafe.JSON, as: TJSON

  describe "encode/1 with ordered objects" do
    test "keeps pair order, including for keys a map would sort differently" do
      object = TJSON.object([{"zeta", 1}, {"alpha", 2}, {"Mid", 3}])

      assert {:ok, iodata} = TJSON.encode(object)
      assert IO.iodata_to_binary(iodata) == ~s({"zeta":1,"alpha":2,"Mid":3})
    end

    test "keeps order in objects nested inside objects, lists and plain maps" do
      inner = TJSON.object([{"y", nil}, {"x", true}])
      term = TJSON.object([{"b", TJSON.object([{"z", [inner, inner]}, {"a", %{"m" => inner}}])}, {"a", []}])

      assert TJSON.encode!(term) ==
               ~s({"b":{"z":[{"y":null,"x":true},{"y":null,"x":true}],"a":{"m":{"y":null,"x":true}}},"a":[]})
    end

    test "encodes an empty object and JSON scalars" do
      assert TJSON.encode!(TJSON.object([])) == "{}"
      assert TJSON.encode!([nil, true, false, 1, 1.5, "text", :atom]) == ~s([null,true,false,1,1.5,"text","atom"])
    end

    test "encodes structs that implement JSON.Encoder and numeric map keys" do
      assert TJSON.encode!(TJSON.object([{"on", ~D[2026-09-16]}, {"counts", %{1 => "one"}}])) ==
               ~s({"on":"2026-09-16","counts":{"1":"one"}})
    end

    test "round-trips through decode_ordered/1 with the same order" do
      term = TJSON.object([{"b", [TJSON.object([{"d", 1}, {"c", 2}])]}, {"a", "x"}])

      assert term |> TJSON.encode!() |> decode_ordered() ==
               {:object, [{"b", [{:object, [{"d", 1}, {"c", 2}]}]}, {"a", "x"}]}
    end
  end

  describe "encode/1 with values that are not JSON" do
    test "returns an error instead of raising" do
      for term <- [{:tuple}, [self()], %{"ref" => make_ref()}, TJSON.object([{"ok", 1}, {"bad", {1, 2}}])] do
        assert {:error, %Protocol.UndefinedError{protocol: JSON.Encoder}} = TJSON.encode(term)
      end
    end

    test "returns an error for invalid UTF-8" do
      assert {:error, exception} = TJSON.encode(TJSON.object([{"text", <<0xFF>>}]))
      assert is_exception(exception)
    end

    test "encode!/1 raises" do
      assert_raise Protocol.UndefinedError, fn -> TJSON.encode!(%{"at" => {2026, 9, 16}}) end
    end
  end

  describe "decode/1" do
    test "decodes binaries and iodata" do
      assert TJSON.decode(~s({"a":[1,2.5,null]})) == {:ok, %{"a" => [1, 2.5, nil]}}
      assert TJSON.decode([~s({"a":), ["1", "}"]]) == {:ok, %{"a" => 1}}
    end

    test "returns an error for invalid JSON" do
      assert {:error, _reason} = TJSON.decode(~s({"a":))
      assert {:error, _reason} = TJSON.decode("")
    end
  end

  describe "to_plain/1" do
    test "turns ordered objects into maps at any depth" do
      term = TJSON.object([{"b", [TJSON.object([{"x", 1}])]}, {"a", %{"k" => TJSON.object([{"q", nil}])}}])

      assert TJSON.to_plain(term) == %{"b" => [%{"x" => 1}], "a" => %{"k" => %{"q" => nil}}}
    end

    test "leaves structs, scalars and plain data untouched" do
      assert TJSON.to_plain(~D[2026-09-16]) == ~D[2026-09-16]
      assert TJSON.to_plain(%{on: ~D[2026-09-16], tags: [:a, "b"]}) == %{on: ~D[2026-09-16], tags: [:a, "b"]}
      assert TJSON.to_plain("text") == "text"
    end
  end

  describe "pretty/1" do
    test "sorts keys at every depth with two-space indentation and a trailing newline" do
      term = %{"b" => [1, %{}, [], %{"z" => nil, "y" => "s"}], :a => %{"c" => 1.5}}

      assert TJSON.pretty(term) == """
             {
               "a": {
                 "c": 1.5
               },
               "b": [
                 1,
                 {},
                 [],
                 {
                   "y": "s",
                   "z": null
                 }
               ]
             }
             """
    end

    test "sorts atom and string keys together by their string form" do
      assert TJSON.pretty(%{:b => 1, "a" => 2, :C => 3}) == ~s({\n  "C": 3,\n  "a": 2,\n  "b": 1\n}\n)
    end

    test "renders scalars and empty containers on one line" do
      assert TJSON.pretty(%{}) == "{}\n"
      assert TJSON.pretty([]) == "[]\n"
      assert TJSON.pretty("text") == ~s("text"\n)
    end

    test "is deterministic and stable after a decode round trip" do
      keys = for i <- 1..40, do: "key_#{i}"
      forward = Map.new(keys, &{&1, [&1]})
      backward = keys |> Enum.reverse() |> Map.new(&{&1, [&1]})

      assert TJSON.pretty(forward) == TJSON.pretty(backward)
      assert forward |> TJSON.pretty() |> JSON.decode!() |> TJSON.pretty() == TJSON.pretty(forward)
    end
  end
end
