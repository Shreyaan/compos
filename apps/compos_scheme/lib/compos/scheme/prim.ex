defmodule Compos.Scheme.Prim do
  @moduledoc """
  One registration per primitive: the name and its one-line doc as the key,
  the fun as the value.

      {"buffer-text", "(buffer-text NAME) — the whole text of NAME."} => fn [name] -> ... end

  A module builds its map this way and hands it to `funs/1` for the
  interpreter and `docs/1` for the help. A key without a doc string, or a
  name registered twice, does not register: `funs/1` raises at boot.
  """

  @doc "NAME => fun, for the interpreter. Raises on a missing doc or a name registered twice."
  def funs(entries) do
    Enum.reduce(entries, %{}, fn
      {{name, doc}, fun}, acc when is_binary(name) and is_binary(doc) and is_function(fun) ->
        if Map.has_key?(acc, name), do: raise("primitive #{name} is registered twice")
        Map.put(acc, name, fun)

      {key, _}, _ ->
        raise "primitive #{inspect(key)} needs a {name, doc} key and a fun"
    end)
  end

  @doc "NAME => doc, for help and apropos."
  def docs(entries), do: Map.new(entries, fn {{name, doc}, _fun} -> {name, doc} end)

  @doc "The fun registered under NAME, or nil."
  def fun(entries, name) do
    Enum.find_value(entries, fn {{n, _doc}, fun} -> n == name && fun end)
  end
end
