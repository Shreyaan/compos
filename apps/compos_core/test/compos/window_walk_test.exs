defmodule Compos.WindowWalkTest do
  @moduledoc """
  The group walk through key dispatch. One key steps the pane to the next
  buffer of the group and a second press goes deeper, not back; the other
  key retraces it. The walk crosses the kinds: a work pane reaches a chat.

  The test presses its own keys, never the real chord — a binding is a
  preference. The scenes come from scheme/packages/group-cycle-test.scm.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Editor, KeyDispatch, Session}

  @scenes Path.expand("../../../../scheme/packages/group-cycle-test.scm", __DIR__)

  test "one key walks the whole group in the pane, and the other comes back" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)

    try do
      assert {:ok, _} = Session.eval(~s|(load "#{@scenes}")|, frame)

      assert {:ok, _} =
               Session.eval(
                 """
                 (group-cycle-test-open!)
                 (let ((gid (buffer-group "*zz-cyc-three*")))
                   (test-buffer! "*zz-cyc-mate*" "")
                   (buffer-add-group! "*zz-cyc-mate*" gid))
                 (delete-other-windows!)
                 (switch-to-buffer-here! "*zz-cyc-mate*")
                 (global-set-key "<f9>" "group-next-buffer")
                 (global-set-key "<f10>" "group-previous-buffer")
                 """,
                 frame
               )

      assert {:ok, ~s|"*zz-cyc-mate*"|} =
               Session.eval("(window-buffer (active-window))", frame)

      # the ring crosses the kinds: a chat is reachable from this work pane
      assert {:ok, ring} = Session.eval("(group-cycle-ring)", frame)
      assert ring =~ "*zz-cyc-three*"

      assert {:ok, window} = Session.eval("(active-window)", frame)

      KeyDispatch.handle_key(frame, "<f9>")
      assert {:ok, first} = Session.eval("(window-buffer (active-window))", frame)
      refute first == ~s|"*zz-cyc-mate*"|
      assert {:ok, ^window} = Session.eval("(active-window)", frame)

      # a second press goes one deeper; it does not flip back
      KeyDispatch.handle_key(frame, "<f9>")
      assert {:ok, second} = Session.eval("(window-buffer (active-window))", frame)
      refute second == first
      refute second == ~s|"*zz-cyc-mate*"|

      # and the other key retraces the walk
      KeyDispatch.handle_key(frame, "<f10>")
      assert {:ok, ^first} = Session.eval("(window-buffer (active-window))", frame)
      KeyDispatch.handle_key(frame, "<f10>")
      assert {:ok, ~s|"*zz-cyc-mate*"|} = Session.eval("(window-buffer (active-window))", frame)
    after
      Session.eval(
        """
        (global-unset-key "<f9>")
        (global-unset-key "<f10>")
        (group-cycle-test-reset!)
        """,
        frame
      )

      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end
end
