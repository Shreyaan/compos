defmodule Compos.TrainingSchemeTest do
  @moduledoc "Runs the focused tutorial lifecycle tests."

  use ExUnit.Case, async: false

  alias Compos.Core.Session

  @file_ Path.expand("../../../../scheme/packages/training-test.scm", __DIR__)
  @lane {:scheme_suite, __MODULE__}

  defp eval!(code) do
    {:ok, out} = Session.eval(code, nil, 30_000, @lane)
    out
  end

  defp names do
    Regex.scan(~r/\(deftest '([^\s()]+)/, File.read!(@file_))
    |> Enum.map(fn [_, name] -> name end)
  end

  @tag timeout: 300_000
  test "training-test.scm passes" do
    eval!(~s{(load "#{@file_}")})
    names = names()
    assert names != [], "the file declares no test"

    failures =
      for name <- names,
          result = Session.eval("(run-test '#{name})", nil, 60_000, @lane),
          result != {:ok, "()"} do
        case result do
          {:ok, failures} -> "#{name} failed: #{failures}"
          {:error, err} -> "#{name} raised: #{err}"
        end
      end

    assert failures == [], Enum.join(failures, "\n")
  end
end
