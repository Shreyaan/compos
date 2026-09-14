defmodule Compos.GroupCycleSchemeTest do
  @moduledoc """
  Runs priv/tests/group-cycle-test.scm alone: one key walks a group
  alone, most recently used first, and flips between the last two.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Editor, KeyDispatch, Session}

  @file_ Path.join([:code.priv_dir(:compos_core), "tests", "group-cycle-test.scm"])
  @lane {:scheme_suite, __MODULE__}

  defp eval!(code) do
    {:ok, out} = Session.eval(code, nil, 30_000, @lane)
    out
  end

  defp names do
    Regex.scan(~r/\(deftest '([^\s()]+)/, File.read!(@file_))
    |> Enum.map(fn [_, name] -> name end)
  end

  @tag timeout: 120_000
  test "group-cycle-test.scm passes" do
    eval!(~s{(load "#{@file_}")})
    names = names()
    assert names != [], "the file declares no test"

    for name <- names do
      case Session.eval("(run-test '#{name})", nil, 60_000, @lane) do
        {:ok, "()"} -> :ok
        {:ok, failures} -> flunk("#{name} failed: #{failures}")
        {:error, err} -> flunk("#{name} raised: #{err}")
      end
    end
  end

  test "group-next-buffer cycles the preferred mode through key dispatch" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)

    try do
      assert {:ok, _} = Session.eval(~s|(load "#{@file_}")|, frame)

      assert {:ok, _} =
               Session.eval(
                 """
                 (group-cycle-test-open!)
                 (buffer-set-local! "*zz-cyc-work-b*" 'mode-name "text-mode")
                 (tile-windows! 'two-pane '("*zz-cyc-work-a*" "*zz-cyc-three*"))
                 (select-window! (window-showing "*zz-cyc-work-a*"))
                 (local-set-key "<f9>" "group-next-buffer")
                 """,
                 frame
               )

      assert {:ok, window} = Session.eval("(active-window)", frame)
      KeyDispatch.handle_key(frame, "<f9>")
      assert {:ok, "\"*zz-cyc-work-b*\""} = Session.eval("(current-buffer)", frame)
      assert {:ok, ^window} = Session.eval("(active-window)", frame)
    after
      Session.eval("(group-cycle-test-reset!)", frame)
      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end

  test "mode-consolidate gathers buffers through key dispatch" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)

    try do
      assert {:ok, _} = Session.eval(~s|(load "#{@file_}")|, frame)

      assert {:ok, _} =
               Session.eval(
                 """
                 (group-consolidate-test-open!)
                 (local-set-key "<f9>" "mode-consolidate")
                 """,
                 frame
               )

      KeyDispatch.handle_key(frame, "<f9>")
      assert {:ok, "3"} = Session.eval("(length (window-list))", frame)
      assert {:ok, "#f"} = Session.eval(~s|(window-showing "*zz-cyc-work-b*")|, frame)
      assert {:ok, "\"*zz-cyc-work-a*\""} = Session.eval("(current-buffer)", frame)
    after
      Session.eval("(group-cycle-test-reset!)", frame)
      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end
end
