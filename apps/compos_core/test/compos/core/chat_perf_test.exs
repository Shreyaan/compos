defmodule Compos.Core.ChatPerfTest do
  use ExUnit.Case, async: false

  alias Compos.Core.ChatPerf

  test "writes parseable append-only events without blocking the caller" do
    slug = "test-#{System.unique_integer([:positive])}"
    path = ChatPerf.path(slug)
    on_exit(fn -> File.rm(path) end)

    assert :ok = ChatPerf.emit(slug, :tool_call, %{duration_ms: 12, backend: TestBackend})

    events = await_events(slug)

    assert [
             %{"kind" => "tool_call", "duration_ms" => 12, "backend" => "Elixir.TestBackend"} =
               event
           ] = events

    assert event["chat"] == slug
    assert is_integer(event["at_us"])
    assert is_integer(event["mono_us"])
    assert String.ends_with?(path, ".chat-perf.jsonl")
  end

  defp await_events(slug, attempts \\ 30)
  defp await_events(_slug, 0), do: []

  defp await_events(slug, attempts) do
    case ChatPerf.events(slug) do
      [] ->
        Process.sleep(10)
        await_events(slug, attempts - 1)

      events ->
        events
    end
  end
end
