defmodule Compos.ZzNotmuchOnlyTest do
  @moduledoc "Temporary: runs priv/tests/notmuch-test.scm alone."

  use ExUnit.Case, async: false

  alias Compos.Core.Session

  @file_ Path.join([:code.priv_dir(:compos_core), "tests", "notmuch-test.scm"])
  @lane {:scheme_suite, __MODULE__}

  defp eval!(code) do
    {:ok, out} = Session.eval(code, nil, 60_000, @lane)
    out
  end

  defp names do
    Regex.scan(~r/\(deftest '([^\s()]+)/, File.read!(@file_))
    |> Enum.map(fn [_, name] -> name end)
  end

  @tag timeout: 300_000
  test "notmuch-test.scm passes" do
    eval!(~s{(load "#{@file_}")})

    bad =
      for name <- names(), reduce: [] do
        acc ->
          case Session.eval("(run-test '#{name})", nil, 60_000, @lane) do
            {:ok, "()"} -> acc
            {:ok, failures} -> ["#{name} failed: #{failures}" | acc]
            {:error, err} -> ["#{name} raised: #{err}" | acc]
          end
      end

    if bad != [], do: flunk(Enum.join(Enum.reverse(bad), "\n---\n"))
  end
end
