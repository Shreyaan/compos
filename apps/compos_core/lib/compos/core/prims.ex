defmodule Compos.Core.Prims do
  @moduledoc "What every primitive module needs: a Scheme string or symbol as a string, a Scheme error, a plist as a map."

  @doc "A Scheme string or symbol as an Elixir string."
  def s({:sym, str}), do: str
  def s(str) when is_binary(str), do: str

  @doc "Raise a Scheme error the caller sees as one."
  def raise_scheme(msg), do: raise(Compos.Scheme.Eval.Error, message: msg)

  # ('cmd "claude-code-acp" 'cwd "/x") -> %{"cmd" => "...", "cwd" => "/x"}
  # Duplicate keys: FIRST wins, matching scheme's plist-get (configs are
  # built by prepending overrides) — Map.new alone would keep the last.
  def plist_to_map(plist) when is_list(plist) do
    plist
    |> Enum.chunk_every(2)
    |> Enum.reverse()
    |> Map.new(fn [k, v] -> {s(k), config_val(s(k), v)} end)
  end

  # 'meta is forwarded to an adapter as JSON, where an OBJECT and an ARRAY
  # are different things — and only the {:sym, _} keys tell them apart
  # ((settingSources ()) is a one-key object; ("user" "local") is a list).
  # Flattening symbols here would erase that, so this value stays raw and
  # the backend converts it.
  def config_val("meta", v), do: v
  def config_val(_k, v), do: plist_val_to_elixir(v)
  def plist_val_to_elixir({:sym, str}), do: str
  def plist_val_to_elixir(v) when is_list(v), do: Enum.map(v, &plist_val_to_elixir/1)
  def plist_val_to_elixir(v), do: v
end
