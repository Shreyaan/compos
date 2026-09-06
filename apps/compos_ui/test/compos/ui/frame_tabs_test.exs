defmodule Compos.Ui.FrameTabsTest do
  @moduledoc """
  The frame modeline carries the groups the frame last stood in. Scheme
  picks them and cuts the list at frame-tabs-limit (frame-tabs); the bar
  renders one span per group, marks the one the frame stands in, and
  counts the rest as one chip that opens the board.
  """

  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Compos.Core.{Editor, Session}

  @endpoint Compos.Ui.Endpoint

  defp eval!(code) do
    case Session.eval(code) do
      {:ok, result} -> result
      other -> flunk("Scheme evaluation failed: #{inspect(other)}")
    end
  end

  defp group_id(name), do: name |> then(&eval!(~s{(group-record-create! "#{&1}")})) |> Jason.decode!()

  defp tab(id), do: ~s{.echo-bar .ml-tab[phx-value-id="#{id}"]}

  defp reset!(limit) do
    Session.eval("""
    (begin
      ;; the records go, the id counter stays: an id this run already
      ;; noted in the MRU must not come back as a new group
      (set! *group-records* '())
      (set! frame-tabs-limit #{limit})
      (set-frame-local! 'current-group #f)
      (set-frame-local! 'previous-group #f)
      (set-frame-local! 'pinned-group #f)
      (frame-group-label-refresh!))
    """)
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    Editor.set_window_buffer("frame-tabs-#{System.unique_integer([:positive])}")
    reset!(3)

    n = System.unique_integer([:positive])
    ids = for i <- 1..5, do: group_id("tabs-#{i}-#{n}")

    on_exit(fn -> reset!(5) end)

    {:ok, conn: build_conn(), ids: ids}
  end

  test "frame-tabs cuts at the limit and counts what it left out", %{ids: ids} do
    assert {:ok, [rows, more]} = Session.call_named("frame-tabs", [])
    assert Enum.map(rows, fn [id, _label, _current] -> id end) == Enum.take(ids, 3)
    assert more == 2
  end

  test "the rail renders the groups, and a click stands in one", %{conn: conn, ids: ids} do
    [first | _] = ids

    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, ".echo-bar .ml-tabs")
    for id <- Enum.take(ids, 3), do: assert(has_element?(view, tab(id)))
    for id <- Enum.drop(ids, 3), do: refute(has_element?(view, tab(id)))
    assert has_element?(view, ".echo-bar .ml-tab-more", "2 more")
    refute has_element?(view, ".echo-bar .ml-tab-on")

    view |> element(tab(first)) |> render_click()

    assert eval!("(frame-group)") == ~s("#{first}")
    assert has_element?(view, ".echo-bar .ml-tab-on")
  end

  test "a prompt does not take the rail away", %{conn: conn, ids: ids} do
    [first | _] = ids

    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, tab(first))

    Editor.minibuffer_activate("Test: ", [], fn _ -> :ok end)
    assert has_element?(view, ".mb-input-row")
    assert has_element?(view, tab(first)), "the tab rail is furniture, not status"

    Editor.minibuffer_close()
    assert has_element?(view, tab(first))
  end

  test "the group the cut left out comes back to the rail once entered", %{conn: conn, ids: ids} do
    last = List.last(ids)

    {:ok, view, _html} = live(conn, "/")
    refute has_element?(view, tab(last))

    eval!(~s{(switch-to-group! "#{last}")})

    assert has_element?(view, tab(last))
    assert has_element?(view, ".echo-bar .ml-tab-on", "tabs-5")
  end
end
