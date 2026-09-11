defmodule Compos.ZzOneSchemeTest do
  use ExUnit.Case
  alias Compos.Core.Session
  @lane {:scheme_suite, __MODULE__}
  @file_path Path.join([:code.priv_dir(:compos_core), "tests", "notmuch-test.scm"])
  @names Regex.scan(~r/\(deftest '([^\s()]+)/, File.read!(@file_path)) |> Enum.map(&List.last/1)

  @tag timeout: 300_000
  test "notmuch scheme tests in file order" do
    {:ok, _} = Session.eval("(load-tests-once!)", nil, 60_000, @lane)
    {:ok, _} = Session.eval("(remove-hook! (quote window-configuration-change-hook) (quote nm--landed-preview!))", nil, 60_000, @lane)

    failures =
      for name <- @names,
          r = Session.eval("(run-test '" <> name <> ")", nil, 60_000, @lane),
          r != {:ok, "()"},
          do: name <> ": " <> inspect(r)

    assert failures == [], "\n" <> Enum.join(failures, "\n")
  end
end
