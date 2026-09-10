defmodule Compos.BufferCatalogTest do
  @moduledoc """
  The catalog indexes what a buffer list reads for a row it never opens.
  A dormant row must answer from memory: before this, every cell of every
  row loaded the whole checkpoint file, and a switcher over a hundred
  sleeping buffers spent half a second reading files off the disk.
  """
  use ExUnit.Case, async: false

  alias Compos.Core.{Buffer, BufferStore, BufferView}

  defp unique(label), do: "*#{label}-#{System.unique_integer([:positive])}*"

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  defp sleeping(label, prepare) do
    name = unique(label)
    {:ok, ^name} = Compos.Core.create_buffer(name)
    prepare.(name)
    :ok = Buffer.checkpoint_now(name)
    [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, name)
    :ok = DynamicSupervisor.terminate_child(Compos.Core.BufferSupervisor, pid)
    assert eventually(fn -> not Buffer.exists?(name) end)
    # the read model drops the row on the DOWN, a beat after the process
    # goes: a lingering row would answer every read and prove nothing
    assert eventually(fn -> BufferView.fetch(name) == :error end)
    name
  end

  # The one measurement that says the fix works: how many times the row
  # read reached the checkpoint file. A counted read is a read of the file.
  defp checkpoint_reads(name, fun) do
    path = BufferStore.lookup(name).checkpoint
    before = File.stat!(path).size
    :erlang.trace(Process.whereis(BufferStore), true, [:receive])
    fun.()
    :erlang.trace(Process.whereis(BufferStore), false, [:receive])
    assert before > 0
    drain_loads(0)
  end

  defp drain_loads(n) do
    receive do
      {:trace, _, :receive, {:"$gen_call", _, {:load, _}}} -> drain_loads(n + 1)
      {:trace, _, :receive, {:"$gen_call", _, {:load_id, _}}} -> drain_loads(n + 1)
      {:trace, _, :receive, _} -> drain_loads(n)
    after
      0 -> n
    end
  end

  test "a dormant buffer's row facts read without loading its checkpoint" do
    name =
      sleeping("catalog", fn name ->
        Buffer.append(name, "row facts", source: :editor)
        Buffer.set_local(name, "mode-name", "text-mode")
        Buffer.set_local(name, "group-ids", ["g1"])
      end)

    reads =
      checkpoint_reads(name, fn ->
        assert Buffer.byte_size(name) == String.length("row facts")
        assert Buffer.path(name) == nil
        assert Buffer.modified?(name) == true
        assert Buffer.get_local(name, "mode-name") == "text-mode"
        assert Buffer.get_local(name, "group-ids") == ["g1"]
        assert Buffer.get_local(name, "no-such-local") == nil
      end)

    assert reads == 0
  end

  test "a local too big to index still answers, from the checkpoint" do
    big = Enum.map(1..3000, &[&1, &1 + 1, "tool"])

    name =
      sleeping("catalog-big", fn name ->
        Buffer.set_local(name, "chat-block-index", big)
        Buffer.set_local(name, "mode-name", "chat-mode")
      end)

    assert BufferStore.local(name, "mode-name") == {:ok, "chat-mode"}
    assert BufferStore.local(name, "chat-block-index") == :error
    assert BufferStore.local(name, "no-such-local") == :absent
    # the catalog cannot give a complete map, so the file does
    assert BufferStore.locals(name) == :error

    # and the counter that the first test reads zero from does count a
    # real load: a local nobody indexed still costs the file
    reads =
      checkpoint_reads(name, fn -> assert Buffer.get_local(name, "chat-block-index") == big end)

    assert reads == 1

    assert Buffer.get_local(name, "mode-name") == "chat-mode"
    assert Buffer.locals(name)["mode-name"] == "chat-mode"
  end

  test "the row moves with a rename and goes with a kill" do
    name =
      sleeping("catalog-rename", fn name ->
        Buffer.set_local(name, "mode-name", "text-mode")
      end)

    new = unique("catalog-renamed")
    assert {:ok, _} = Compos.Core.rename_buffer(name, new)
    assert BufferStore.known?(new)
    refute BufferStore.known?(name)
    assert BufferStore.fact(new, :size) == {:ok, 0}

    Compos.Core.kill_buffer(new)
    refute BufferStore.known?(new)
    assert BufferStore.fact(new, :size) == :error
  end

  test "a live buffer never answers from the catalog" do
    name = unique("catalog-live")
    {:ok, ^name} = Compos.Core.create_buffer(name)
    Buffer.set_local(name, "mode-name", "text-mode")
    :ok = Buffer.checkpoint_now(name)

    Buffer.append(name, "later", source: :editor)
    Buffer.set_local(name, "mode-name", "morg-mode")

    assert BufferStore.fact(name, :size) == {:ok, 0}
    assert Buffer.byte_size(name) == 5
    assert Buffer.get_local(name, "mode-name") == "morg-mode"

    Compos.Core.kill_buffer(name)
  end
end
