defmodule Compos.BufferCreateFileTest do
  use ExUnit.Case, async: false

  alias Compos.Core.Session
  @lane {:scheme_suite, __MODULE__}

  test "a save from a path-named buffer that never read its file raises and leaves the file" do
    dir = Path.join(Compos.Core.home(), "buffer-create-file-test")
    File.mkdir_p!(dir)
    path = Path.join(dir, "guarded.txt")
    File.write!(path, "on disk\n")

    assert {:ok, _} =
             Session.eval(
               ~s{(begin (raw-buffer-create "#{path}") (buffer-append! "#{path}" "in memory\\n"))},
               nil,
               30_000,
               @lane
             )

    assert {:error, message} =
             Session.eval(
               ~s{(with-current-buffer "#{path}" (lambda () (run-command "save-buffer")))},
               nil,
               30_000,
               @lane
             )

    assert message =~ "never read it"
    assert File.read!(path) == "on disk\n"

    Session.eval(~s{(begin (buffer-mark-saved! "#{path}") (buffer-kill! "#{path}"))}, nil, 30_000, @lane)
    File.rm(path)
  end
end
