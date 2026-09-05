defmodule Compos.LlmInsertSchemeTest do
  use ExUnit.Case, async: false

  alias Compos.Core.Session

  @file_ Path.join([:code.priv_dir(:compos_core), "tests", "llm-insert-test.scm"])
  @lane {:scheme_suite, __MODULE__}

  defp names do
    Regex.scan(~r/\(deftest '([^\s()]+)/, File.read!(@file_))
    |> Enum.map(fn [_, name] -> name end)
  end

  @tag timeout: 120_000
  test "llm-insert-test.scm passes" do
    assert {:ok, _} = Session.eval(~s{(load "#{@file_}")}, nil, 30_000, @lane)

    for name <- names() do
      case Session.eval("(run-test '#{name})", nil, 60_000, @lane) do
        {:ok, "()"} -> :ok
        {:ok, failures} -> flunk("#{name} failed: #{failures}")
        {:error, error} -> flunk("#{name} raised: #{error}")
      end
    end
  end
end
