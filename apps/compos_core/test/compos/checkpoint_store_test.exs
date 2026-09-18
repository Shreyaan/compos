defmodule Compos.CheckpointStoreTest do
  @moduledoc """
  The log is the text. A checkpoint carries the text only when the log
  cannot answer for it, and a checkpoint from before that rule (version
  1) still restores.
  """
  use ExUnit.Case, async: false

  alias Compos.Core.{Buffer, BufferHistoryStore, BufferStore}

  defp unique(label), do: "*#{label}-#{System.unique_integer([:positive])}*"

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  defp evict(name) do
    :ok = Buffer.checkpoint_now(name)
    [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, name)
    :ok = DynamicSupervisor.terminate_child(Compos.Core.BufferSupervisor, pid)
    assert eventually(fn -> not Buffer.exists?(name) end)
  end

  defp checkpoint(id), do: id |> BufferStore.checkpoint_path() |> File.read!() |> :erlang.binary_to_term()

  defp write_checkpoint(id, term),
    do: BufferStore.atomic_write(BufferStore.checkpoint_path(id), :erlang.term_to_binary(term))

  test "a recording buffer keeps its text in the log, not in the checkpoint" do
    name = unique("log-text")
    {:ok, ^name} = Compos.Core.create_buffer(name)
    Buffer.append(name, "the log holds this", source: :user)
    id = Buffer.id(name)
    evict(name)

    cp = checkpoint(id)
    assert cp.version == 2
    refute Map.has_key?(cp, :text)
    assert cp.size == 18
    assert BufferHistoryStore.size(id) > 0

    # dormant: the facts from the row, the text from the log
    assert Buffer.byte_size(name) == 18
    assert Buffer.text(name) == "the log holds this"
    refute Buffer.exists?(name)

    # awake: the text and the history come back from the log
    Buffer.append(name, "!", source: :user)
    assert Buffer.exists?(name)
    assert Buffer.text(name) == "the log holds this!"
    assert Enum.any?(Buffer.change_log(name), &(&1.actor["id"] =~ "user"))

    Compos.Core.kill_buffer(name)
  end

  test "a buffer that stopped recording keeps its text in the checkpoint" do
    name = unique("stopped-text")
    {:ok, ^name} = Compos.Core.create_buffer(name)
    :ok = Buffer.provenance_stop(name)
    Buffer.append(name, "unrecorded", source: :user)
    id = Buffer.id(name)
    evict(name)

    cp = checkpoint(id)
    assert cp.version == 2
    assert cp.text == "unrecorded"
    assert Buffer.text(name) == "unrecorded"

    Compos.Core.kill_buffer(name)
  end

  test "a version 1 checkpoint still restores, text and all" do
    name = unique("v1")
    {:ok, ^name} = Compos.Core.create_buffer(name)
    Buffer.append(name, "from before", source: :user)
    id = Buffer.id(name)
    evict(name)

    cp = checkpoint(id)
    write_checkpoint(id, cp |> Map.delete(:size) |> Map.merge(%{version: 1, text: "from before"}))
    Compos.Core.BufferStore.reindex()

    assert Buffer.text(name) == "from before"
    Buffer.append(name, " and after", source: :user)
    assert Buffer.text(name) == "from before and after"
    evict(name)
    assert checkpoint(id).version == 2
    refute Map.has_key?(checkpoint(id), :text)
    assert Buffer.text(name) == "from before and after"

    Compos.Core.kill_buffer(name)
  end

  test "the migration strips the text of a version 1 checkpoint only when the log agrees" do
    agreed = unique("migrate-agreed")
    {:ok, ^agreed} = Compos.Core.create_buffer(agreed)
    Buffer.append(agreed, "same bytes", source: :user)
    agreed_id = Buffer.id(agreed)
    evict(agreed)
    write_checkpoint(agreed_id, checkpoint(agreed_id) |> Map.delete(:size) |> Map.merge(%{version: 1, text: "same bytes"}))

    stale = unique("migrate-stale")
    {:ok, ^stale} = Compos.Core.create_buffer(stale)
    Buffer.append(stale, "log bytes", source: :user)
    stale_id = Buffer.id(stale)
    evict(stale)
    write_checkpoint(stale_id, checkpoint(stale_id) |> Map.delete(:size) |> Map.merge(%{version: 1, text: "other bytes"}))

    File.rm(Path.join(BufferStore.dir(), ".checkpoints-v2"))
    :ok = BufferStore.migrate([BufferStore.checkpoint_path(agreed_id), BufferStore.checkpoint_path(stale_id)])
    assert File.exists?(Path.join(BufferStore.dir(), ".checkpoints-v2"))

    assert checkpoint(agreed_id).version == 2
    refute Map.has_key?(checkpoint(agreed_id), :text)
    assert checkpoint(agreed_id).size == 10
    assert checkpoint(stale_id).version == 1
    assert checkpoint(stale_id).text == "other bytes"

    BufferStore.reindex()
    assert Buffer.text(agreed) == "same bytes"
    assert Buffer.text(stale) == "other bytes"

    Compos.Core.kill_buffer(agreed)
    Compos.Core.kill_buffer(stale)
  end
end
