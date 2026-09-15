defmodule Compos.ChatPeekRenderTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{Buffer, Editor, Session}

  defp eval!(code) do
    {:ok, result} = Session.eval(code)
    result
  end

  defp leaves(%{buffer: _} = leaf), do: [leaf]
  defp leaves(map) when is_map(map), do: map |> Map.values() |> Enum.flat_map(&leaves/1)
  defp leaves(list) when is_list(list), do: Enum.flat_map(list, &leaves/1)
  defp leaves(_), do: []

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
      '(mode-name "chat-mode" render-mode "agent" agent-saved-mark 5
        agent-blocks ((0 5 "prose")) agent-slug "do-not-copy-runtime"))
    (listing-preview! "*zz-peek-owner*" "*zz-peek-chat*")
    """)

    leaf =
      Enum.find(
        leaves(Editor.render_state()),
        &(&1.buffer != "*zz-peek-owner*" and Map.get(&1, :agent))
      )

    assert leaf.agent.blocks == [[0, 5, "prose"]]
    assert leaf.agent.mark == 5
    assert leaf.agent.slug in [nil, false]
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
    leaf = Enum.find(leaves(Editor.render_state()), &Map.get(&1, :agent))
    assert Enum.map(leaf.agent.blocks, &Enum.at(&1, 2)) == ["prose", "user"]
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
