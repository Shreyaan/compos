defmodule Compos.SilentTurnTest do
  @moduledoc """
  The other silence. A connector can take the prompt and say nothing at
  all: no text, no tool, no result, no end. The turn then never closes on
  the wire, and the chat waits at "waiting..." for good.

  The Agent recovers. It waits the grace the chat gives it for the
  connector's FIRST event, ends the turn itself, and says so. The chat
  then reconnects the session, because a connector that answered a whole
  turn with silence is not fit for the next one.
  """

  use Compos.Case

  alias Compos.Core.{Agent, Buffer}

  defp eventually(fun, tries \\ 80) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end

  defp chat(script) do
    slug =
      String.trim(
        eval!(
          ~s[(execute* "go" '(permission-mode auto connector "stub" backend "stub" script (#{script})))]
        ),
        "\""
      )

    {slug, Agent.info(slug).buffer}
  end

  setup do
    eval!("(set-symbol-value! 'chat-silent-turn-seconds 1)")
    # the reconnect must land on the stub too: a test never starts a real
    # adapter, and this one restarts the session on purpose
    eval!(~s[(define-connector! "stub" '(hidden #t backend "stub" script ()))])

    on_exit(fn ->
      eval!("(set-symbol-value! 'chat-silent-turn-seconds 180)")
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Compos.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*chat:") or Buffer.get_local(name, "agent-slug"),
          do: Compos.Core.kill_buffer(name)
      end)
    end)

    :ok
  end

  test "a turn the connector never answers is ended by the grace" do
    {slug, buf} = chat("((type hang))")

    # the prompt is on the wire and nothing has come back
    assert eventually(fn -> match?(%{status: :running, silent: true}, Agent.info(slug)) end)

    # the grace expires: the turn ends and the transcript says why
    assert eventually(fn -> Buffer.text(buf) =~ "the connector said nothing for" end)

    # the chat is free again: nothing waits on the turn that never spoke
    assert eventually(fn -> Buffer.get_local(buf, "chat-turn-active") in [false, nil] end)
    assert Buffer.get_local(buf, "chat-activity") in [false, nil]
  end

  test "the chat gets a live runtime back" do
    {_slug, buf} = chat("((type hang))")

    assert eventually(fn -> Buffer.text(buf) =~ "the connector said nothing for" end)

    # the silent session is gone and the buffer wears a new one
    assert eventually(fn ->
             case Buffer.get_local(buf, "agent-slug") do
               s when is_binary(s) -> s in Agent.list()
               _ -> false
             end
           end)
  end

  test "a connector that speaks keeps its turn" do
    {slug, _buf} = chat(~s[((type chunk text "still working") (type hang))])

    # one chunk is the whole proof: the connector is alive, so the turn
    # runs as long as it needs to
    assert eventually(fn -> match?(%{status: :running}, Agent.info(slug)) end)
    Process.sleep(1_500)
    assert match?(%{status: :running, silent: false}, Agent.info(slug))
  end

  test "the chat turns the recovery off" do
    eval!("(set-symbol-value! 'chat-silent-turn-seconds 0)")

    {slug, _buf} = chat("((type hang))")

    assert eventually(fn -> match?(%{status: :running}, Agent.info(slug)) end)
    Process.sleep(1_500)
    assert match?(%{status: :running, silent: false}, Agent.info(slug))
  end
end
