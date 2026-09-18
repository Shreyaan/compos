defmodule Compos.DisplayTest do
  @moduledoc """
  The display model answers the rows of a window from the render payload,
  with no client: every client draws the same rows.
  """
  use ExUnit.Case

  alias Compos.Core.{Buffer, Display, Editor}

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    Editor.set_total_rows(20)
    name = "zz-display-#{System.unique_integer([:positive])}"
    Editor.set_window_buffer(name)
    Buffer.append(name, Enum.map_join(1..5000, "\n", &"row #{&1}"), source: :editor)
    Buffer.goto(name, 0)
    on_exit(fn -> Compos.Core.kill_buffer(name) end)
    {:ok, name: name}
  end

  test "a window builds the rows of its viewport, not the buffer" do
    leaf = Editor.render_state().tree
    {drawn, _entry} = Display.window(leaf, nil)

    assert length(drawn.lines) <= leaf.rows * 3 + 8
    refute drawn.client_scroll?
  end

  # The browser owns the caret of the window it edits; any other window
  # shows point as a server-drawn cursor.
  test "only a window the caret does not own draws the cursor" do
    leaf = Editor.render_state().tree
    {served, _} = Display.window(leaf, nil)
    {native, _} = Display.window(leaf, nil, caret_owner: leaf.id)

    assert hd(served.lines).segs == [{"r", "cursor"}, {"ow 1", ""}]
    assert hd(native.lines).segs == [{"row 1", ""}]
  end

  test "a render with the same inputs reuses the rows it built" do
    leaf = Editor.render_state().tree
    {_, {key, visible, _} = entry} = Display.window(leaf, nil)
    {_, {^key, again, _}} = Display.window(leaf, entry)

    assert :erts_debug.same(visible, again)
  end

  test "a peek card takes more rows, up to a bound" do
    leaf = %{Editor.render_state().tree | window_class: "listing-peek"}
    {drawn, _} = Display.window(leaf, nil)

    assert length(drawn.lines) == 2_000
  end
end
