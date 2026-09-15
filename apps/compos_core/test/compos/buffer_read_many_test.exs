defmodule Compos.BufferReadManyTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{Buffer, BufferView, Editor}

  setup do
    name = "*bulk-#{System.unique_integer([:positive])}*"
    {:ok, ^name} = Compos.Core.create_buffer(name, text: "abc")
    on_exit(fn -> Compos.Core.kill_buffer(name) end)
    %{name: name}
  end

  test "projects only requested data and preserves missing values and order", %{name: name} do
    Buffer.set_locals(name, %{
      "mode-name" => "text-mode",
      "unrelated" => List.duplicate("large", 50_000)
    })

    assert Buffer.read_many([name, "missing-buffer"], [:size, :path], ["missing", "mode-name"]) ==
             [
               [name, 3, false, false, "text-mode"],
               ["missing-buffer", false, false, false, false]
             ]

    assert {:ok, [3, "text-mode", false]} =
             BufferView.project(name, [:size], ["mode-name", "missing"])
  end

  test "a missing live read-model row falls back to current buffer state", %{name: name} do
    Buffer.set_local(name, "fresh", 42)
    BufferView.forget(name)
    assert Buffer.read_many([name], [:size], ["fresh"]) == [[name, 3, 42]]
  end

  test "dormant metadata does not wake the buffer, including an unindexed local", %{name: name} do
    large = String.duplicate("x", 2048)
    Buffer.set_locals(name, %{"mode-name" => "text-mode", "large" => large})
    Editor.set_window_buffer("*scratch*")
    Buffer.checkpoint_now(name)
    [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, name)
    :ok = DynamicSupervisor.terminate_child(Compos.Core.BufferSupervisor, pid)

    Enum.reduce_while(1..100, nil, fn _, _ ->
      if Buffer.exists?(name),
        do:
          (
            Process.sleep(5)
            {:cont, nil}
          ),
        else: {:halt, nil}
    end)

    refute Buffer.exists?(name)

    assert Buffer.read_many([name], [:size], ["mode-name", "large", "missing"]) ==
             [[name, 3, "text-mode", large, false]]

    refute Buffer.exists?(name)
  end
end
