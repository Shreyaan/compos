defmodule Compos.HiddenWindowsTest do
  @moduledoc """
  A hidden window keeps its id, buffer and history without a pane. The
  desktop saves the hidden windows of each frame, and a restore makes
  them again.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Editor, Session}

  test "the desktop view carries the hidden windows, and a restore makes them again" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)

    try do
      assert {:ok, _} =
               Session.eval(
                 """
                 (test-buffer! "*zz-hw-a*" "")
                 (test-buffer! "*zz-hw-b*" "")
                 (delete-other-windows!)
                 (window-hidden-clear!)
                 (switch-to-buffer-here! "*zz-hw-a*")
                 (window-new-hidden! "*zz-hw-b*")
                 """,
                 frame
               )

      view = Editor.desktop_view(frame)
      assert [%{buffer: "*zz-hw-b*"}] = view.hidden

      # the desktop file holds a hidden window as a 7-tuple leaf spec
      spec = {:leaf, "*zz-hw-b*", 0, 0, false, 0, ["*zz-hw-a*"]}
      assert :ok = Editor.set_hidden_windows([spec], frame)
      assert [{_id, "*zz-hw-b*"}] = Editor.hidden_windows(frame)
      assert [%{buffer: "*zz-hw-b*", history: ["*zz-hw-a*"]}] = Editor.desktop_view(frame).hidden

      # a restore from an older desktop, with no hidden windows, clears them
      assert :ok = Editor.set_hidden_windows([], frame)
      assert [] = Editor.hidden_windows(frame)
    after
      Session.eval(
        """
        (window-hidden-clear!)
        (buffer-kill! "*zz-hw-a*")
        (buffer-kill! "*zz-hw-b*")
        """,
        frame
      )

      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end

  test "a pane swaps with a hidden window, and both keep their ids" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)

    try do
      assert {:ok, _} =
               Session.eval(
                 """
                 (test-buffer! "*zz-hw-a*" "")
                 (test-buffer! "*zz-hw-b*" "")
                 (delete-other-windows!)
                 (window-hidden-clear!)
                 (switch-to-buffer-here! "*zz-hw-a*")
                 """,
                 frame
               )

      pane = Editor.active_window(frame)
      hidden = Editor.new_hidden_window("*zz-hw-b*", frame)
      assert :ok = Editor.swap_hidden_window(pane, hidden)
      assert [{^hidden, "*zz-hw-b*"}] = Editor.list_windows(frame)
      assert [{^pane, "*zz-hw-a*"}] = Editor.hidden_windows(frame)
      assert Editor.active_window(frame) == hidden

      # a line of both: the hidden one comes back beside the other
      assert :ok = Editor.arrange_line(:h, 0.5, [pane, hidden], frame)
      assert [{^pane, "*zz-hw-a*"}, {^hidden, "*zz-hw-b*"}] = Editor.list_windows(frame)
      assert [] = Editor.hidden_windows(frame)

      # a buffer kill takes a hidden window with no past away
      assert :ok = Editor.arrange_line(:h, 0.5, [pane], frame)
      assert [{^hidden, "*zz-hw-b*"}] = Editor.hidden_windows(frame)
      Session.eval(~s|(buffer-kill! "*zz-hw-b*")|, frame)
      assert [] = Editor.hidden_windows(frame)
    after
      Session.eval(
        """
        (window-hidden-clear!)
        (when (buffer-known? "*zz-hw-a*") (buffer-kill! "*zz-hw-a*"))
        (when (buffer-known? "*zz-hw-b*") (buffer-kill! "*zz-hw-b*"))
        """,
        frame
      )

      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end
end
