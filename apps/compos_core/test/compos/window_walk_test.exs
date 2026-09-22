defmodule Compos.WindowWalkTest do
  @moduledoc """
  Cmd-up and Cmd-down walk the frame's context: every buffer of the group,
  in the pane the user stands in, skipping nothing. The test presses its
  own keys, never the real chord, and drives the same KeyDispatch path the
  browser uses. The scenes come from scheme/packages/window-walk-test.scm.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Editor, KeyDispatch, Session}

  @scenes Path.join([
            Path.dirname(__ENV__.file),
            "..",
            "..",
            "..",
            "..",
            "scheme",
            "packages",
            "window-walk-test.scm"
          ])
          |> Path.expand()

  test "one key walks the group's buffers in the pane, and the other comes back" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)

    try do
      assert {:ok, _} = Session.eval(~s|(load "#{@scenes}")|, frame)

      assert {:ok, ~s|"zz-walk-work"|} =
               Session.eval(
                 """
                 (walk-test-open!)
                 (global-set-key "<f9>" "focus-down")
                 (global-set-key "<f10>" "focus-up")
                 (window-buffer (active-window))
                 """,
                 frame
               )

      assert {:ok, window} = Session.eval("(active-window)", frame)
      assert {:ok, ring} = Session.eval("(window-walk-ring)", frame)

      # the walk reaches the buffers the pane fill pool declines
      assert ring =~ "zz-walk-chat"
      assert ring =~ "zz-walk-view"

      KeyDispatch.handle_key(frame, "<f9>")
      assert {:ok, first} = Session.eval("(window-buffer (active-window))", frame)
      refute first == ~s|"zz-walk-work"|
      assert {:ok, ^window} = Session.eval("(active-window)", frame)

      # a second press goes one deeper, it does not flip back
      KeyDispatch.handle_key(frame, "<f9>")
      assert {:ok, second} = Session.eval("(window-buffer (active-window))", frame)
      refute second == first
      refute second == ~s|"zz-walk-work"|

      # and the other key retraces the walk
      KeyDispatch.handle_key(frame, "<f10>")
      assert {:ok, ^first} = Session.eval("(window-buffer (active-window))", frame)
      KeyDispatch.handle_key(frame, "<f10>")
      assert {:ok, ~s|"zz-walk-work"|} = Session.eval("(window-buffer (active-window))", frame)
    after
      Session.eval(
        """
        (global-unset-key "<f9>")
        (global-unset-key "<f10>")
        (walk-test-reset!)
        """,
        frame
      )
      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end
end
