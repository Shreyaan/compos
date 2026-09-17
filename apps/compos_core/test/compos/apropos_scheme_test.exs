defmodule Compos.AproposSchemeTest do
  @moduledoc """
  Runs priv/tests/apropos-test.scm alone: the catalog, the search, the cold
  start, and the Elixir primitives the interpreter binds.

  The whole Scheme suite runs in scheme_suite_test.exs. This wrapper is for
  working on discovery itself, where running every other file's tests is waste.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.Session

  @file_ Path.join([:code.priv_dir(:compos_core), "tests", "apropos-test.scm"])
  @lane {:scheme_suite, __MODULE__}

  defp eval!(code) do
    {:ok, out} = Session.eval(code, nil, 30_000, @lane)
    out
  end

  defp names do
    Regex.scan(~r/\(deftest '([^\s()]+)/, File.read!(@file_))
    |> Enum.map(fn [_, name] -> name end)
  end

  @tag timeout: 180_000
  test "apropos-test.scm passes" do
    eval!(~s{(load "#{@file_}")})
    names = names()
    assert names != [], "the file declares no test"

    # every test runs: one red test must not hide the ones after it
    failures =
      for name <- names,
          report = reduce(name, Session.eval("(run-test '#{name})", nil, 60_000, @lane)),
          report != nil,
          do: report

    assert failures == [], "\n" <> Enum.join(failures, "\n")
  end

  defp reduce(_name, {:ok, "()"}), do: nil
  defp reduce(name, {:ok, out}), do: "  #{name}\n      #{out}"
  defp reduce(name, {:error, err}), do: "  #{name}\n      raised: #{err}"
end
