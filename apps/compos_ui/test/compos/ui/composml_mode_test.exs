defmodule Compos.Ui.ComposMLModeTest do
  use ExUnit.Case
  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session, TS, TreeSitter}

  test "ComposML mode loads normally, accepts keys, and rebuilds its parser on re-entry" do
    TreeSitter.load_bundled()
    name = "composml-mode-#{System.unique_integer([:positive])}"
    {:ok, _} = Compos.Core.create_buffer(name)
    on_exit(fn -> Session.eval(~s|(buffer-kill! "#{name}")|) end)
    Buffer.append(name, "<c-modeline>buffer</c-modeline>", source: :editor)
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.set_window_buffer(name)
    Editor.local_bind_key(name, ["<f9>"], "composml-mode")
    KeyDispatch.handle_key("<f9>")
    assert Buffer.get_local(name, "mode-name") == "composml-mode"
    assert Buffer.get_local(name, "ts-lang") == "composml"
    assert TS.ts_highlight("composml", Buffer.text(name)) != []
    assert {:ok, ~s("composml-mode")} = Session.eval(~s|(auto-mode-for "example.composml")|)

    assert {:ok, _} =
             Session.eval(
               ~s|(with-current-buffer "#{name}" (lambda () (set-mode! "text-mode") (set-mode! "composml-mode")))|
             )

    assert Buffer.get_local(name, "ts-lang") == "composml"
    assert {:ok, entries} = Session.eval(~s|(apropos "composml-mode")|)
    assert entries =~ "syntax"
  end
end
