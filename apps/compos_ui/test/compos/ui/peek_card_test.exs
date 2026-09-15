defmodule Compos.Ui.PeekCardTest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  alias Compos.Core.{Editor, Session}

  defp leaves(%{type: :leaf} = node), do: [node]
  defp leaves(%{children: children}), do: Enum.flat_map(children, &leaves/1)
  defp leaves(%{first: a, second: b}), do: leaves(a) ++ leaves(b)

  test "a peek renders only an inert card body and its dismiss button" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)
    try do
      assert {:ok, _} = Session.eval("""
      (test-buffer! "*zz-ui-peek-owner*" "row")
      (test-buffer! "*zz-ui-peek-target*" "<script>unsafe()</script>")
      (switch-to-buffer-here! "*zz-ui-peek-owner*")
      (listing-preview! "*zz-ui-peek-owner*" "*zz-ui-peek-target*")
      """, frame)
      state = Editor.render_state(frame)
      card = Enum.find(leaves(state.tree), &String.contains?(&1.window_class || "", "listing-peek"))
      assert card
      html = render_component(&Compos.Ui.EditorLive.window/1,
        node: Map.put(card, :lines, []), active: state.active, completion: nil)
      assert html =~ ~s(phx-hook="PeekCard")
      assert html =~ ~s(class="peek-card-body")
      assert html =~ "&lt;script&gt;"
      assert html =~ "Dismiss preview (q)"
      assert html =~ "--peek-source-window:"
      refute html =~ "contenteditable"
      refute html =~ "modeline"
      refute html =~ "<script>"
      assert length(Regex.scan(~r/<button\b/, html)) == 1
      assert {:ok, _} = Session.eval("""
      (buffer-set-locals! "*zz-ui-peek-target*"
        '(mode-name "chat-mode" render-mode "agent" agent-saved-mark 25
          agent-blocks ((0 25 "prose"))))
      (listing-preview! "*zz-ui-peek-owner*" "*zz-ui-peek-target*")
      """, frame)
      state = Editor.render_state(frame)
      {tree, _} = Compos.Ui.EditorLive.decorate_tree(state.tree, %{}, %{}, state.active)
      card = Enum.find(leaves(tree), &String.contains?(&1.window_class || "", "listing-peek"))
      rich = render_component(&Compos.Ui.EditorLive.window/1,
        node: card, active: state.active, completion: nil)
      assert rich =~ "ag-prose"
      refute rich =~ ~s(phx-hook="AgentScroll")
      refute rich =~ "contenteditable"

    after
      Session.eval("""
      (listing-preview-dismiss! "*zz-ui-peek-owner*")
      (buffer-kill! "*zz-ui-peek-owner*")
      (buffer-kill! "*zz-ui-peek-target*")
      """, frame)
      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end
end
