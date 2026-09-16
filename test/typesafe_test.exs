defmodule TypesafeTest do
  use ExUnit.Case
  doctest Typesafe

  test "greets the world" do
    assert Typesafe.hello() == :world
  end
end
