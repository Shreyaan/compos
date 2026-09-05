defmodule Compos.FaceBatchTest do
  @moduledoc """
  A theme is hundreds of face writes. `Editor.set_faces/1` applies them as
  one change, so the page never renders a half-applied theme (a cleared
  default size moved every window's scroll).
  """
  use ExUnit.Case, async: false
  alias Compos.Core.{Editor, Events, Session}

  defp drain_changes(n \\ 0) do
    receive do
      {:editor_change, _} -> drain_changes(n + 1)
    after
      200 -> n
    end
  end

  setup do
    Editor.clear_face("zz-batch-a")
    Editor.clear_face("zz-batch-b")
    on_exit(fn ->
      Editor.clear_face("zz-batch-a")
      Editor.clear_face("zz-batch-b")
    end)
    :ok
  end

  test "a batch applies clears and sets in one broadcast" do
    Editor.set_face("zz-batch-a", %{"fg" => "red", "weight" => "700"})
    Events.subscribe_editor()
    drain_changes()

    Editor.set_faces([
      {:clear, "zz-batch-a"},
      {:set, "zz-batch-a", %{"fg" => "blue"}},
      {:set, "zz-batch-b", %{"bg" => "white"}},
      {:set, "zz-batch-b", %{"fg" => "black"}}
    ])

    assert drain_changes() == 1
    faces = Editor.faces()
    assert faces["zz-batch-a"] == %{"fg" => "blue"}, "the clear forgot the weight"
    assert faces["zz-batch-b"] == %{"bg" => "white", "fg" => "black"}
  end

  test "a batch that changes nothing broadcasts nothing" do
    Events.subscribe_editor()
    drain_changes()
    Editor.set_faces([{:clear, "zz-batch-never"}])
    assert drain_changes() == 0
  end

  test "face-batch! is the Scheme door: theme-apply! reaches the table through it" do
    {:ok, _} =
      Session.eval(~S"""
      (face-batch! '((set zz-batch-a fg "green" weight "600") (clear zz-batch-b)))
      """)

    assert Editor.faces()["zz-batch-a"] == %{"fg" => "green", "weight" => "600"}
  end
end
