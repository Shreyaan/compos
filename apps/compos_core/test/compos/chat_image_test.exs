defmodule Compos.ChatImageTest do
  @moduledoc """
  A pasted image is a file, a block, and a content block on the wire: the
  bytes land in <compos-home>/attachments, the transcript names the file
  above the input, and the next message carries both the path (in its text)
  and the picture itself (as an ACP image block).
  """

  use ExUnit.Case

  alias Compos.Core.{Agent, Buffer, Session}

  # a 1x1 transparent PNG
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  @buf "*zz-ichat*"

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  defp inject(agent, frame), do: send(agent, {:acp_data, Jason.encode!(frame) <> "\n"})

  defp handshake(agent) do
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 2_000
    inject(agent, %{jsonrpc: "2.0", id: iid, result: %{protocolVersion: 1}})
    assert_receive {:frame, %{"method" => "session/new", "id" => sid}}, 2_000
    inject(agent, %{jsonrpc: "2.0", id: sid, result: %{sessionId: "s1"}})
  end

  defp pending, do: Buffer.get_local(@buf, "chat-pending-images") || []

  setup do
    Compos.Test.FakeTransport.own!()
    Application.put_env(:compos_core, :acp_transport, Compos.Test.FakeTransport)

    on_exit(fn ->
      Application.delete_env(:compos_core, :acp_transport)
      Enum.each(Agent.list(), &Agent.kill/1)
      Compos.Core.kill_buffer(@buf)
    end)

    :ok
  end

  test "a pasted image becomes a file, a transcript block, and an image block on the wire" do
    eval!("(buffer-create " <> inspect(@buf) <> ")")
    slug = String.trim(eval!("(chat-attach-agent! " <> inspect(@buf) <> " \"claude-code\")"), "\"")

    assert_receive {:transport_open, agent}, 2_000
    handshake(agent)
    wait_until(fn -> Agent.info(slug).status == :idle end)

    # the paste itself, through the very function the paste hook calls
    paste =
      "(with-current-buffer " <>
        inspect(@buf) <>
        " (lambda () (chat-image-paste! \"image\" " <> inspect(@png) <> " \"image/png\")))"

    assert eval!(paste) == "#t"

    assert [["image/png", path]] = pending()
    assert File.exists?(path)
    assert File.read!(path) == Base.decode64!(@png)

    # the transcript names it, above the input, as its own block
    assert Buffer.text(@buf) =~ "[image " <> Path.basename(path) <> "]"

    assert Enum.any?(Buffer.get_local(@buf, "agent-blocks") || [], fn
             [_, _, "image", p, m] -> p == path and m == "image/png"
             _ -> false
           end)

    # ...and it rides with the next message
    eval!("(agent-send-msg! " <> inspect(slug) <> " \"what is this\")")

    assert_receive {:frame, %{"method" => "session/prompt", "params" => p}}, 2_000
    [text_block | rest] = p["prompt"]

    assert text_block["type"] == "text"
    assert text_block["text"] =~ "what is this"
    # the path rides in the text as well: a lane that cannot take image
    # content can still open the file
    assert text_block["text"] =~ path

    assert rest == [%{"type" => "image", "mimeType" => "image/png", "data" => @png}]

    # the attachment is spent: it rides once and no further
    assert pending() == []

    File.rm(path)
  end
end
