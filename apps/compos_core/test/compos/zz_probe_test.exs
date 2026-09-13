defmodule Compos.ZzProbeTest do
  use ExUnit.Case, async: false
  alias Compos.Core.Session

  @file_ Path.join([:code.priv_dir(:compos_core), "tests", "group-switch-test.scm"])
  @lane {:scheme_suite, __MODULE__}

  defp eval!(code) do
    {:ok, out} = Session.eval(code, nil, 30_000, @lane)
    out
  end

  @tag timeout: 120_000
  test "probe" do
    eval!(~s{(load "#{@file_}")})
    IO.puts("selected-frame: " <> eval!("(selected-frame)"))
    IO.puts("frames: " <> eval!("(frame-list)"))
    eval!("(t--sw-setup!)")
    IO.puts("after setup selected: " <> eval!("(selected-frame)"))
    id = eval!(~s{(group-record-create! "zz-probe")})
    IO.puts("id: " <> id)
    IO.puts("owner: " <> eval!(~s{(group-frame-owner #{id})}))
    IO.puts("here?: " <> eval!(~s{(group-here? #{id})}))
    IO.puts("mru: " <> eval!("(group-ids-mru)"))
    IO.puts("mru-all: " <> eval!("(group-ids-mru-all)"))
    IO.puts("other frame: " <> eval!("(define zz-other (make-frame!)) "))
    IO.puts("selected after make-frame: " <> eval!("(selected-frame)"))
    eval!("(t--sw-done!)")
  end
end
