defmodule Compos.GroupSwitchNewTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{Session, KeyDispatch}

  defp eval!(code) do
    assert {:ok, result} = Session.eval(code)
    result
  end

  setup do
    path = Path.join([:code.priv_dir(:compos_core), "tests", "group-switch-test.scm"])
    eval!(~s{(load "#{path}")})
    on_exit(fn -> Session.eval("(t--sw-done!)") end)
    :ok
  end

  test "group listing restores recency and omits creation rows" do
    for name <- ["group-switch-uses-mru-when-the-visible-frame-is-homogeneous",
                 "group-switch-preserves-mru-in-a-mixed-frame",
                 "switch-to-group-can-move-the-current-buffer-into-a-new-context"] do
      assert eval!("(run-test '#{name})") == "()"
    end
  end

  test "modal creation command dispatches and releases its map before naming" do
    eval!("""
    (t--sw-setup!)
    (run-command "group-switch")
    (define-key "group-switch-modal-map" "<f9>" "group-switch-new")
    """)
    assert eval!("(and (member \"group-switch-modal-map\" (buffer-minor-maps (minibuffer-buffer))) #t)") == "#t"
    KeyDispatch.handle_key("<f9>")
    assert eval!("(and (minibuffer-state) #t)") == "#t"
    assert eval!("(frame-local 'group-switch-new-action)") == "#f"
    assert eval!("(and (member \"group-switch-modal-map\" (buffer-minor-maps (minibuffer-buffer))) #t)") == "#f"
    eval!("(minibuffer-cancel!)")
    assert eval!("(group-resolve-id \"zz-new-cancelled\")") == "#f"
  end

  test "C-c C-n in the group switcher starts a new group" do
    eval!("(t--sw-setup!) (run-command \"group-switch\")")
    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("C-n")
    assert eval!("(frame-local 'group-switch-new-action)") == "#f"
    assert eval!("(and (member \"group-switch-modal-map\" (buffer-minor-maps (minibuffer-buffer))) #t)") == "#f"
    eval!("(minibuffer-cancel!)")
  end

  test "cancelling the group selector removes its modal keymap" do
    eval!("(t--sw-setup!) (run-command \"group-switch\") (minibuffer-cancel!)")
    assert eval!("(frame-local 'group-switch-new-action)") == "#f"
    assert eval!("(and (member \"group-switch-modal-map\" (buffer-minor-maps (minibuffer-buffer))) #t)") == "#f"
  end
end
