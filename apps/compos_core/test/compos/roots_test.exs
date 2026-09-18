defmodule Compos.Core.RootsTest do
  use ExUnit.Case, async: false

  alias Compos.Core.Roots

  test "a root holds its value until it is dropped" do
    key = {:roots_test, make_ref()}
    assert Roots.put(key, :value)
    assert Roots.get(key) == :value
    assert {key, :value} in Roots.all()
    assert Roots.drop(key) == :ok
    assert Roots.get(key) == nil
    assert Roots.drop(key) == :ok
  end

  test "a take hands the value to one caller only" do
    key = {:roots_test, make_ref()}
    Roots.put(key, :once)

    takes =
      1..20
      |> Enum.map(fn _ -> Task.async(fn -> Roots.take(key) end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(takes, &(&1 == :once)) == 1
    assert Roots.get(key) == nil
  end
end
