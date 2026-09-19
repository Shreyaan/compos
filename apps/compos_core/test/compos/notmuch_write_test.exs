defmodule Compos.NotmuchWriteTest do
  use ExUnit.Case, async: false
  alias Compos.Core.Session

  test "a failed tag write surfaces stderr instead of reporting success" do
    assert {:error, reason} =
             Session.eval(
               ~S|(nm--tag-result "1\nCouldn't open lockfile: Operation not permitted")|
             )

    assert reason =~ "Notmuch tag failed"
    assert reason =~ "Operation not permitted"
    assert {:ok, ~s("")} = Session.eval(~S|(nm--tag-result "0\n")|)
  end

  test "tag command captures the actual exit status, including silent failures" do
    path = Path.join(System.tmp_dir!(), "notmuch-write-#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\nexit 7\n")

    assert {:ok, _} =
             Session.eval(
               "(begin (define zz-write-program notmuch-program) (define zz-write-host notmuch-host) (define zz-write-profile notmuch-profile) (set! notmuch-host \"\") (set! notmuch-profile \"\") (set! notmuch-program #{inspect("sh " <> path)}))"
             )

    on_exit(fn ->
      Session.eval(
        "(begin (set! notmuch-program zz-write-program) (set! notmuch-host zz-write-host) (set! notmuch-profile zz-write-profile))"
      )

      File.rm(path)
    end)

    assert {:error, reason} = Session.eval(~S|(nm--run "tag -inbox -- no-messages")|)
    assert reason =~ "Notmuch tag failed"
    assert reason =~ "7"
    File.write!(path, "#!/bin/sh\nprintf 'write denied' >&2\nexit 1\n")
    assert {:error, reason} = Session.eval(~S|(nm--run "tag -inbox -- no-messages")|)
    assert reason =~ "write denied"
  end
end
