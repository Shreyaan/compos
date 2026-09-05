defmodule Compos.WhatsappTest do
  @moduledoc """
  The WhatsApp modes use a held MCP seam. These tests verify the list,
  conversation, refresh, and reply paths without external traffic.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}

  @list_buffer "*WhatsApp*"
  @chat_buffer "*whatsapp:123@s.whatsapp.net*"

  defp eval!(source) do
    {:ok, printed} = Session.eval(source)
    printed
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp open_chat do
    eval!(~S|(run-command "whatsapp")|)
    eval!(~S|(switch-to-buffer! "*WhatsApp*")|)
    eval!(~S|(list-goto-first-entry "*WhatsApp*")|)
    press("RET")
  end

  setup do
    Compos.Core.kill_buffer(@list_buffer)
    Compos.Core.kill_buffer(@chat_buffer)
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()

    eval!(~S"""
    (begin
      (define *zz-whatsapp-list-fetches* 0)
      (define *zz-whatsapp-message-fetches* 0)
      (define *zz-whatsapp-sent* #f)
      (set! *whatsapp-call*
        (lambda (server tool args &optional cb)
          (cond
            ((equal? tool "list_chats")
             (set! *zz-whatsapp-list-fetches*
                   (+ *zz-whatsapp-list-fetches* 1))
             "{\"jid\":\"123@s.whatsapp.net\",\"name\":\"Mukund\",\"last_message_time\":\"2026-09-05T11:49:38+05:30\",\"last_message\":\"it's the weekend\",\"last_is_from_me\":1}")
            ((equal? tool "list_messages")
             (set! *zz-whatsapp-message-fetches*
                   (+ *zz-whatsapp-message-fetches* 1))
             (let ((text
                     "[2026-09-05 11:49:38] Chat: Mukund From: Me: it's the weekend\n"))
               (if cb (cb #t text) text)))
            ((equal? tool *whatsapp-reply-tool*)
             (set! *zz-whatsapp-sent* args)
             (if cb (cb #t "{\"success\":true}") "{\"success\":true}"))
            (else
              (if cb (cb #f "unknown tool") ""))))))
    """)

    on_exit(fn ->
      eval!("(set! *whatsapp-call* mcp-call!)")
      Editor.minibuffer_close()
      Compos.Core.kill_buffer(@list_buffer)
      Compos.Core.kill_buffer(@chat_buffer)
    end)

    :ok
  end

  test "RET opens a conversation and g refreshes it" do
    open_chat()

    assert Buffer.text(@list_buffer) =~ "Mukund"
    assert Buffer.text(@list_buffer) =~ "me: it's the weekend"
    assert Buffer.text(@chat_buffer) =~ "Chat: Mukund"
    assert Buffer.text(@chat_buffer) =~ "r reply"
    assert eval!(~S|(buffer-local "*whatsapp:123@s.whatsapp.net*" 'whatsapp-jid)|) ==
             ~S("123@s.whatsapp.net")
    assert eval!("*zz-whatsapp-message-fetches*") == "1"

    press("g")

    assert eval!("*zz-whatsapp-message-fetches*") == "2"
  end

  test "r collects a reply and sends it to the open chat" do
    open_chat()

    press("r")
    "On my way" |> String.graphemes() |> Enum.each(&KeyDispatch.handle_key/1)
    press("RET")

    sent = eval!("*zz-whatsapp-sent*")
    assert sent =~ ~S(recipient "123@s.whatsapp.net")
    assert sent =~ ~S(message "On my way")
    assert eval!("*zz-whatsapp-message-fetches*") == "2"
  end

  test "mode setup keeps restored conversation identity and commands" do
    open_chat()

    eval!(~S"""
    (with-current-buffer "*whatsapp:123@s.whatsapp.net*"
      (lambda () (set-mode! "whatsapp-chat-mode")))
    """)
    eval!(~S|(switch-to-buffer! "*whatsapp:123@s.whatsapp.net*")|)
    press("g")

    assert eval!("*zz-whatsapp-message-fetches*") == "2"
    assert Buffer.text(@chat_buffer) =~ "it's the weekend"
  end
end
