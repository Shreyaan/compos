defmodule Compos.ZzWebSpawnGroupTest do
  use ExUnit.Case

  alias Compos.Core.Session

  @lane {:zz_web_spawn_group, __MODULE__}

  defp eval(code), do: Session.eval(code, nil, 60_000, @lane)

  defp eval!(code) do
    {:ok, out} = eval(code)
    out
  end

  @tests [
    "a-page-joins-the-group-of-the-window-that-opened-it",
    "a-page-opens-in-the-frame-group-when-the-window-has-none-and-cycles-views",
    "every-page-is-its-own-tab-in-the-current-group",
    "a-page-keeps-markdown-and-preview-owns-the-rendering"
  ]

  @tag timeout: 120_000
  test "the web spawn-group tests pass" do
    loaded = eval!("(begin (load-tests-once!) (test-names))")

    for t <- @tests do
      assert loaded =~ t, "missing test \#{t}"
    end

    failures =
      for t <- @tests,
          result = eval("(run-test '#{t})"),
          out = report(t, result),
          out != nil,
          do: out

    assert failures == [], "\n" <> Enum.join(failures, "\n")
  end

  defp report(_t, {:ok, "()"}), do: nil
  defp report(t, {:ok, out}), do: "  \#{t}\n      \#{out}"
  defp report(t, {:error, msg}), do: "  \#{t}\n      raised: \#{msg}"
end
