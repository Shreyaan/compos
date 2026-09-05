defmodule Compos.WindowFillTest do
  @moduledoc "One pool answers which buffers may fill a window: the Scheme tests, in this daemon."
  use ExUnit.Case, async: false

  alias Compos.Core.{Editor, Session}

  setup do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)

    on_exit(fn ->
      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end)

    %{frame: frame}
  end

  test "the pool", %{frame: frame} do
    for name <- [
          "the-pool-is-the-groups-members-and-nothing-from-elsewhere",
          "a-peek-and-a-popup-are-not-fill-candidates",
          "a-listing-seeds-no-new-group",
          "the-visible-verbs-take-the-windows-as-they-stand"
        ] do
      {:ok, out} = Session.eval("(begin (load-tests!) (run-test '#{name}))", frame)
      assert out == "()", "#{name}: #{out}"
    end
  end
end
