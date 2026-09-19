defmodule Compos.Core.Roots do
  @moduledoc """
  The GC root table: every Scheme value that Elixir holds outside the
  interpreter store.

  A closure that leaves Scheme (a handler, a callback that waits for a
  reply, a timer's function, a task's result) is invisible to the frame
  GC, which sees only the store and the roots the Session hands it. An
  entry here is such a root: the GC keeps the frames the value captures
  for as long as the entry stays.

  The table belongs to `Compos.Core.SchemeTables`, which keeps it across
  a Session restart. A call before the table exists (a unit test with no
  Session) roots nothing: there is no GC to defend against, so `put/2`
  answers false and every read answers nil.

  Two kinds of entry:

    * a slot: a single handler under a fixed key such as `{:on_event, "lsp"}`,
      set by a Scheme primitive and read on every event;
    * a hold: a callback under a fresh key such as `{:llm, ref}`, put
      before the value escapes and dropped once the callback fired.
  """

  @table :compos_escaped_closures

  @doc "The table name, for the GC's root set and the Session's special cases."
  def table, do: @table

  defp table?, do: :ets.whereis(@table) != :undefined

  @doc "Root VALUE under KEY. Answers false when there is no table."
  def put(key, value) do
    if table?() do
      :ets.insert(@table, {key, value})
      true
    else
      false
    end
  end

  @doc "The value under KEY, or nil."
  def get(key) do
    if table?() do
      case :ets.lookup(@table, key) do
        [{_, value}] -> value
        [] -> nil
      end
    end
  end

  @doc """
  Remove KEY and answer its value, or nil, in one step. Use it where the
  entry must be consumed once: two callers never both get the value.
  """
  def take(key) do
    if table?() do
      case :ets.take(@table, key) do
        [{_, value}] -> value
        [] -> nil
      end
    end
  end

  @doc "Remove KEY. Answers :ok whether or not it was there."
  def drop(key) do
    if table?(), do: :ets.delete(@table, key)
    :ok
  end

  @doc "Every entry, for the GC's root set."
  def all, do: if(table?(), do: :ets.tab2list(@table), else: [])
end
