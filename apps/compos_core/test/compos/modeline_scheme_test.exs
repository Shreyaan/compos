defmodule Compos.ModelineSchemeTest do
  @moduledoc """
  Runs priv/tests/modeline-test.scm alone: compact buffer names, and the
  summary and jj segments of the dashboard line.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.Session

  @file_ Path.join([:code.priv_dir(:compos_core), "tests", "modeline-test.scm"])
  @lane {:scheme_suite, __MODULE__}

  defp eval!(code) do
    {:ok, out} = Session.eval(code, nil, 30_000, @lane)
    out
  end

  # the names come from the file, not from (test-names): another test in
  # the same VM may have loaded every file already
  defp names do
    Regex.scan(~r/\(deftest '([^\s()]+)/, File.read!(@file_))
    |> Enum.map(fn [_, name] -> name end)
  end

  test "modeline-test.scm passes" do
    eval!(~s{(load "#{@file_}")})
    names = names()
    assert names != [], "the file declares no test"

    for name <- names do
      case Session.eval("(run-test '#{name})", nil, 30_000, @lane) do
        {:ok, "()"} -> :ok
        {:ok, failures} -> flunk("#{name} failed: #{failures}")
        {:error, err} -> flunk("#{name} raised: #{err}")
      end
    end
  end

  test "a dashboard catches up on another frame through the configuration hook" do
    alias Compos.Core.{Buffer, Editor}
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)
    name = "*zz-dashboard-cross-frame*"

    try do
      eval!(~s|(test-buffer! "#{name}" "")|)
      eval!(~s|(dashboard--sync! "#{name}")|)
      assert Buffer.get_local(name, "dashboard-dirty") == true
      assert Buffer.get_local(name, "dashboard-line-blocks") == nil

      {window, _, ^frame} =
        Enum.find(Editor.list_windows_all(), fn {_, _, fid} -> fid == frame end)

      :ok = Editor.window_set_buffer(window, name)
      await_dashboard(name, 100)
      assert is_list(Buffer.get_local(name, "dashboard-line-blocks"))

      # The event runs from the original frame while the reader is elsewhere.
      Editor.select_frame(previous)
      eval!(~s|(buffer-set-local! "#{name}" 'minor-modes '("zz-cross-frame-mode"))|)
      eval!(~s|(dashboard--sync! "#{name}")|)
      assert Buffer.get_local(name, "dashboard-line") =~ "zz-cross-frame"
      assert Buffer.get_local(name, "dashboard-dirty") == false
    after
      Editor.delete_frame(frame)
      Editor.select_frame(previous)
      eval!(~s|(buffer-kill! "#{name}")|)
    end
  end

  defp await_dashboard(name, attempts) do
    if Compos.Core.Buffer.get_local(name, "dashboard-dirty") == false do
      :ok
    else
      assert attempts > 0, "configuration hook did not materialize the dashboard"
      Process.sleep(10)
      await_dashboard(name, attempts - 1)
    end
  end
end
