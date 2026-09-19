defmodule Compos.SessionRestartTest do
  use Compos.Case, async: false
  alias Compos.Core.Session

  test "a Session restart with a chat open loads init.scm" do
    {:ok, _} = Session.eval(~s{(begin (buffer-create "zz-restart-chat") (buffer-set-local! "zz-restart-chat" 'mode-name "chat-mode") #t)})
    pid = Process.whereis(Compos.Core.Session)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}, 5_000
    new =
      Enum.find_value(1..300, fn _ ->
        Process.sleep(100)
        p = Process.whereis(Compos.Core.Session)
        if p && p != pid && Session.ready?(), do: p
      end)
    assert new, "the Session did not come back"
    assert {:ok, "2"} = Session.eval("(+ 1 1)")
  end
end
