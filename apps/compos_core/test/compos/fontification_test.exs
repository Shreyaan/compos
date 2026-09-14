defmodule Compos.FontificationTest do
  use ExUnit.Case
  alias Compos.Core.{Buffer, BufferView, Events, TS}

  setup do
    name = "fontification-#{System.unique_integer([:positive])}"

    text =
      "value = \"\"\"\n" <> Enum.map_join(1..200, "\n", &"line #{&1}") <> "\n\"\"\"\nnext = 42\n"

    {:ok, _} = Compos.Core.create_buffer(name, text: text)
    Buffer.set_local(name, "ts-lang", "elixir")
    Events.subscribe_display(name)
    {:ok, name: name, text: text}
  end

  defp faces(name, version, start, stop, tries \\ 100)
  defp faces(_, _, _, _, 0), do: flunk("fontification did not arrive")

  defp faces(name, version, start, stop, tries) do
    cache = BufferView.get(name, :fontification) || []

    case Enum.find(cache, fn {v, s, e, _} -> v == version and s <= start and e >= stop end) do
      {_, _, _, spans} ->
        spans

      nil ->
        receive do
          {:buffer_display, ^name} -> :ok
        after
          20 -> :ok
        end

        faces(name, version, start, stop, tries - 1)
    end
  end

  test "visible faces include syntax that starts outside the viewport", %{name: name, text: text} do
    {start, _} = :binary.match(text, "line 100")
    stop = start + 30
    v = Buffer.version(name)
    assert :ok == Buffer.request_fontification(name, v, start, stop)
    spans = faces(name, v, start, stop)

    expected =
      TS.ts_highlight("elixir", text) |> Enum.filter(fn {s, e, _} -> s < stop and e > start end)

    assert spans == expected
    assert Enum.any?(spans, fn {s, _, scope} -> s < start and scope == "string" end)
  end

  test "an edit supersedes old requests and preserves two displayed ranges", %{name: name} do
    old = Buffer.version(name)
    Buffer.request_fontification(name, old, 0, 40)
    Buffer.insert_at(name, 0, "# λ\n")
    v = Buffer.version(name)
    Buffer.request_fontification(name, v, 0, 40)
    Buffer.request_fontification(name, v, 100, 140)
    reference = TS.ts_highlight("elixir", Buffer.text(name))
    assert faces(name, v, 0, 40) == Enum.filter(reference, fn {s, e, _} -> s < 40 and e > 0 end)

    assert faces(name, v, 100, 140) ==
             Enum.filter(reference, fn {s, e, _} -> s < 140 and e > 100 end)

    assert Enum.all?(BufferView.get(name, :fontification), fn {version, _, _, _} ->
             version == v
           end)
  end

  test "a fork keeps its snapshot when the source parser receives an edit", %{text: text} do
    res = TS.ts_state_new("elixir")
    TS.ts_state_highlight(res, text)
    fork = TS.ts_state_fork(res, "elixir")
    TS.ts_state_edit(res, 0, 0, 4, 0, 0, 0, 0, 1, 0)
    TS.ts_state_highlight(res, "# x\n" <> text)

    assert TS.ts_state_highlight_range(fork, text, 0, 40) ==
             Enum.filter(TS.ts_highlight("elixir", text), fn {s, e, _} -> s < 40 and e > 0 end)
  end

  test "leaving the language drops its display faces", %{name: name} do
    v = Buffer.version(name)
    Buffer.request_fontification(name, v, 0, 40)
    assert faces(name, v, 0, 40) != []
    Buffer.set_local(name, "ts-lang", false)
    assert BufferView.get(name, :fontification) == []
  end

  test "provisional faces follow repeated byte edits without becoming fresh", %{name: name} do
    v = Buffer.version(name)
    Buffer.request_fontification(name, v, 100, 140)
    original = faces(name, v, 100, 140)

    Buffer.insert_at(name, 0, "λ\n")
    assert [{^v, 103, 143, shifted}] = BufferView.get(name, :fontification)
    assert shifted == Enum.map(original, fn {s, e, face} -> {s + 3, e + 3, face} end)
    assert Buffer.version(name) > v

    Buffer.delete_range(name, 0, 3)
    assert [{^v, 100, 140, ^original}] = BufferView.get(name, :fontification)

    # Completing another window must not erase this window's provisional faces.
    current = Buffer.version(name)
    Buffer.request_fontification(name, current, 0, 40)
    faces(name, current, 0, 40)
    assert {v, 100, 140, original} in BufferView.get(name, :fontification)
  end
end
