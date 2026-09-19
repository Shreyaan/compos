defmodule Compos.Ui.PeekCardTest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  alias Compos.Core.{Editor, Session}

  defp leaves(%{type: :leaf} = node), do: [node]
  defp leaves(%{children: children}), do: Enum.flat_map(children, &leaves/1)
  defp leaves(%{first: a, second: b}), do: leaves(a) ++ leaves(b)

  test "an onscreen target receives the preview border instead of a floating copy" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)
    try do
      assert {:ok, _} = Session.eval(~S"""
      (test-buffer! "*zz-visible-owner*" "owner")
      (test-buffer! "*zz-visible-target*" "already visible")
      (test-buffer! "*zz-hidden-target*" "hidden")
      (switch-to-buffer-here! "*zz-visible-owner*")
      (define *visible-preview-home* (active-window))
      (split-window! 'h 0.5)
      (other-window!)
      (switch-to-buffer-here! "*zz-visible-target*")
      (select-window! *visible-preview-home*)
      (local-set-key "q" "listing-peek-dismiss")
      (listing-preview! "*zz-visible-owner*" "*zz-visible-target*")
      """, frame)
      assert {:ok, "#f"} = Session.eval("(float-open?)", frame)
      state = Editor.render_state(frame)
      {tree, _} = Compos.Ui.EditorLive.decorate_tree(state.tree, %{}, %{}, state.active)
      target = Enum.find(leaves(tree), &(&1.buffer == "*zz-visible-target*"))
      assert target.highlighted
      assert state.active != target.id
      html = render_component(&Compos.Ui.EditorLive.window/1,
        node: Map.put(target, :lines, []), active: state.active, completion: nil)
      assert html =~ "preview-highlight"
      refute html =~ "peek-card-body"

      assert {:ok, _} = Session.eval(~S{(listing-preview! "*zz-visible-owner*" "*zz-hidden-target*")}, frame)
      refute Enum.find(leaves(Editor.render_state(frame).tree), &(&1.id == target.id)).highlighted
      assert {:ok, "#t"} = Session.eval("(float-open?)", frame)
      assert {:ok, _} = Session.eval(~S{(listing-preview! "*zz-visible-owner*" "*zz-visible-target*")}, frame)
      assert {:ok, "#f"} = Session.eval("(float-open?)", frame)
      Compos.Core.KeyDispatch.handle_key(frame, "q")
      refute Enum.find(leaves(Editor.render_state(frame).tree), &(&1.id == target.id)).highlighted
      assert {:ok, "#t"} = Session.eval(~S{(buffer-exists? "*zz-visible-target*")}, frame)
    after
      Session.eval(~S{(listing-preview-dismiss! "*zz-visible-owner*")
        (for-each buffer-kill! '("*zz-visible-owner*" "*zz-visible-target*" "*zz-hidden-target*"))}, frame)
      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end

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

      assert {:ok, _} = Session.eval(~S"""
      (buffer-set-locals! "*zz-ui-peek-target*"
        '(mode-name "linkedin-detail-mode" render-mode "html" preview-renderer "html"))
      (buffer-replace-range! "*zz-ui-peek-target*" 0 (buffer-size "*zz-ui-peek-target*")
        "<h1>Saved LinkedIn detail</h1>")
      (buffer-sleep! "*zz-ui-peek-target*")
      (listing-preview! "*zz-ui-peek-owner*" "*zz-ui-peek-target*")
      """, frame)
      state = Editor.render_state(frame)
      {tree, _} = Compos.Ui.EditorLive.decorate_tree(state.tree, %{}, %{}, state.active)
      card = Enum.find(leaves(tree), &String.contains?(&1.window_class || "", "listing-peek"))
      rich = render_component(&Compos.Ui.EditorLive.window/1,
        node: card, active: state.active, completion: nil)
      assert rich =~ "peek-document"
      assert rich =~ "Saved LinkedIn detail"
      assert rich =~ ~s(sandbox="allow-same-origin")
      refute rich =~ "allow-scripts"
      assert {:ok, "#f"} = Session.eval(~S{(buffer-exists? "*zz-ui-peek-target*")}, frame)

      assert {:ok, _} = Session.eval(~S"""
      (buffer-create "*zz-ui-peek-target*")
      (sentry--apply-detail! "*zz-ui-peek-target*"
        '(id "123" shortId "TEST-1" title "Saved Sentry detail"
          metadata (type "Error" value "failure <tag>") status "unresolved"))
      (buffer-set-locals! "*zz-ui-peek-target*"
        '(mode-name "sentry-detail-mode" render-blocks #f sentry-detail-issue #f))
      (buffer-sleep! "*zz-ui-peek-target*")
      (listing-preview! "*zz-ui-peek-owner*" "*zz-ui-peek-target*")
      """, frame)
      state = Editor.render_state(frame)
      {tree, _} = Compos.Ui.EditorLive.decorate_tree(state.tree, %{}, %{}, state.active)
      card = Enum.find(leaves(tree), &String.contains?(&1.window_class || "", "listing-peek"))
      rich = render_component(&Compos.Ui.EditorLive.window/1,
        node: card, active: state.active, completion: nil)
      assert rich =~ "Saved Sentry detail"
      assert rich =~ "c-card"
      assert rich =~ "failure &lt;tag&gt;"
      refute rich =~ "Raw issue JSON"
      assert {:ok, "#f"} = Session.eval(~S{(buffer-exists? "*zz-ui-peek-target*")}, frame)

      assert {:ok, _} = Session.eval(~S"""
      (define-list-mode! "zz-saved-card-mode"
        (list 'rows (lambda (buf) (error "Preview must not fetch rows"))
              'header (lambda (buf) "Saved card list")
              'key (lambda (buf row) row)
              'collection "c-list"
              'composml (lambda (buf row)
                (list 'tag "c-card" 'text row))))
      (buffer-create "*zz-ui-peek-target*")
      (buffer-set-locals! "*zz-ui-peek-target*"
        '(mode-name "zz-saved-card-mode" list-mode "zz-saved-card-mode"
          list-entries ("Saved project card") render-mode "blocks" render-blocks #f))
      (buffer-sleep! "*zz-ui-peek-target*")
      (listing-preview! "*zz-ui-peek-owner*" "*zz-ui-peek-target*")
      """, frame)
      state = Editor.render_state(frame)
      {tree, _} = Compos.Ui.EditorLive.decorate_tree(state.tree, %{}, %{}, state.active)
      card = Enum.find(leaves(tree), &String.contains?(&1.window_class || "", "listing-peek"))
      rich = render_component(&Compos.Ui.EditorLive.window/1,
        node: card, active: state.active, completion: nil)
      assert rich =~ "Saved project card"
      assert rich =~ "semantic-list"
      assert rich =~ "semantic-item"
      assert {:ok, "#f"} = Session.eval(~S{(buffer-exists? "*zz-ui-peek-target*")}, frame)

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
