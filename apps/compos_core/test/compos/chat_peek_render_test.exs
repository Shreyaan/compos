defmodule Compos.ChatPeekRenderTest do
  use Compos.Case, async: false
  alias Compos.Core.{Buffer, Editor}

  defp leaves(%{buffer: _} = leaf), do: [leaf]
  defp leaves(map) when is_map(map), do: map |> Map.values() |> Enum.flat_map(&leaves/1)
  defp leaves(list) when is_list(list), do: Enum.flat_map(list, &leaves/1)
  defp leaves(_), do: []

  # the preview window: a rich chat draws as a block tree
  defp rich_leaf do
    Enum.find(
      leaves(Editor.render_state()),
      &(&1.buffer != "*zz-peek-owner*" and &1.render_mode == "blocks" and is_list(&1.blocks))
    )
  end

  defp plist([{:sym, k}, v | _], k), do: v
  defp plist([_, _ | rest], k), do: plist(rest, k)
  defp plist(_, _), do: nil

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()

    for b <- ["*zz-peek-owner*", "*zz-peek-chat*", "*zz-peek-plain*"],
        do: Compos.Core.create_buffer(b, text: "hello")

    Editor.set_window_buffer("*zz-peek-owner*")

    on_exit(fn ->
      eval!(~S{(listing-preview-dismiss! "*zz-peek-owner*")})
      Editor.set_window_buffer("*scratch*")

      for b <- ["*zz-peek-owner*", "*zz-peek-chat*", "*zz-peek-plain*"],
          do: Compos.Core.kill_buffer(b)
    end)

    :ok
  end

  test "peek preserves rich chat blocks and clears them when switching to plain text" do
    eval!(~S"""
    (buffer-set-locals! "*zz-peek-chat*"
      '(mode-name "chat-mode" render-mode "blocks" agent-saved-mark 5
        agent-blocks ((0 5 "prose")) agent-slug "do-not-copy-runtime"))
    (listing-preview! "*zz-peek-owner*" "*zz-peek-chat*")
    """)

    leaf = rich_leaf()

    assert Buffer.get_local(leaf.buffer, "agent-blocks") == [[0, 5, "prose"]]
    assert Buffer.get_local(leaf.buffer, "agent-saved-mark") == 5
    assert Buffer.get_local(leaf.buffer, "agent-slug") in [nil, false]
    # the copy draws as a rich chat: its transcript is the one prose block
    [transcript | _] = leaf.blocks
    assert length(plist(transcript, "children")) == 1
    assert Buffer.read_only?(leaf.buffer)
    assert Editor.current_buffer() == "*zz-peek-owner*"
    assert Buffer.text("*zz-peek-chat*") == "hello"
    eval!(~S{(listing-preview! "*zz-peek-owner*" "*zz-peek-plain*")})
    assert Buffer.get_local(leaf.buffer, "render-mode") in [nil, false]
    assert Buffer.get_local(leaf.buffer, "agent-blocks") in [nil, false]
  end

  test "saved chat format becomes user and prose blocks without restoring identity" do
    raw = "#+chat: (title \"Do not rename preview\")\n\n### You\nhi\n\n### Assistant\n**hello**\n"
    Buffer.replace_range("*zz-peek-chat*", 0, 5, raw, source: :editor)
    Buffer.set_local("*zz-peek-chat*", "mode-name", "chat-mode")
    eval!(~S{(listing-preview! "*zz-peek-owner*" "*zz-peek-chat*")})
    leaf = rich_leaf()
    assert Enum.map(Buffer.get_local(leaf.buffer, "agent-blocks"), &Enum.at(&1, 2)) == ["prose", "user"]
    refute Buffer.text(leaf.buffer) =~ "#+chat:"
    assert Buffer.text(leaf.buffer) =~ "**hello**"
    assert Buffer.text("*zz-peek-chat*") == raw
    assert Buffer.get_local(leaf.buffer, "chat-title") in [nil, false]
  end

  test "peek enables an arbitrary source mode and preserves its rich projection" do
    eval!(~S"""
    (define-mode "zz-peek-custom-mode"
      (lambda () (buffer-set-local! (current-buffer) 'zz-mode-enabled #t)))
    (buffer-set-locals! "*zz-peek-plain*"
      '(mode-name "zz-peek-custom-mode" render-mode "blocks"
        render-blocks ((text "rich mode content"))))
    (listing-preview! "*zz-peek-owner*" "*zz-peek-plain*")
    """)

    leaf = Enum.find(leaves(Editor.render_state()), &(&1.mode == "zz-peek-custom-mode"))
    assert leaf.render_mode == "blocks"
    assert leaf.blocks != []
    assert Buffer.get_local(leaf.buffer, "zz-mode-enabled") == true
    assert Buffer.read_only?(leaf.buffer)
    assert Buffer.text("*zz-peek-plain*") == "hello"
  end
end
