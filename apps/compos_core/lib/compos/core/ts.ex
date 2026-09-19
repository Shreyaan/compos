defmodule Compos.Core.TS do
  @moduledoc """
  Tree-sitter NIF bindings (native/compos_ts). Byte offsets throughout —
  matching Buffer. Languages: elixir, json, rust (growing).

  All functions degrade gracefully for unknown languages (empty/nil).
  """

  use Rustler, otp_app: :compos_core, crate: "compos_ts"

  @doc "Highlight spans: [{start, stop, scope}] from the grammar's query."
  def ts_highlight(_lang, _text), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Structural nav (op: forward|backward|up|down) -> byte pos or nil."
  def ts_nav(_lang, _text, _pos, _op), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The named node {kind, start, stop} and its neighbours. An empty kind
  means the smallest node covering the range; nested nodes can share a
  range, so the kind names which one the caller stands on.
  op: at | parent | child | next | prev | top -> {kind, start, stop} or nil.
  """
  def ts_node(_lang, _text, _kind, _start, _stop, _op), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Arbitrary query: [{capture, start, stop}]."
  def ts_query_nif(_lang, _text, _query), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Highlight LINES as one text in LANG, so a construct that spans lines
  keeps its colour. Answer one list per line: the {start, stop, scope} runs
  in that line's own bytes, in order, with no overlap. Where captures nest,
  the inner one wins; where the grammar names one node twice, the later
  name wins.
  """
  def highlight_lines(lang, lines) do
    text = Enum.join(lines, "\n")

    spans =
      lang
      |> ts_highlight(text)
      |> Enum.with_index()
      |> Enum.sort_by(fn {{s, e, _}, i} -> {s, -e, i} end)
      |> Enum.map(&elem(&1, 0))

    {rows, _} =
      Enum.map_reduce(lines, 0, fn line, at ->
        stop = at + byte_size(line)
        {line_runs(spans, at, stop), stop + 1}
      end)

    rows
  end

  defp line_runs(spans, at, stop) do
    inside =
      for {s, e, scope} <- spans,
          s < stop,
          e > at,
          do: {max(s, at) - at, min(e, stop) - at, scope}

    cuts =
      inside
      |> Enum.flat_map(fn {s, e, _} -> [s, e] end)
      |> Enum.uniq()
      |> Enum.sort()

    cuts
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] ->
      case inside |> Enum.filter(fn {s, e, _} -> s <= a and e >= b end) |> List.last() do
        nil -> []
        {_, _, scope} -> [{a, b, scope}]
      end
    end)
  end

  @doc """
  Several queries over one parse of TEXT: one [{capture, start, stop}]
  list per query.
  """
  def ts_queries(lang, text, queries) do
    ts_queries_nif(lang, text, queries)
  rescue
    # the old library before a restart: one parse per query
    ErlangError -> Enum.map(queries, &ts_query_nif(lang, text, &1))
  end

  @doc false
  def ts_queries_nif(_lang, _text, _queries), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  One query over many ranges of TEXT: [{capture, start, stop}] in TEXT's
  offsets. Each range parses as a document of its own, and the query
  compiles once. Markdown reads its inline ranges this way.
  """
  def ts_query_ranges(lang, text, ranges, query) do
    ts_query_ranges_nif(lang, text, ranges, query)
  rescue
    # a daemon that swapped this module in before its restart still runs
    # the old library: ask the old NIF once per range
    ErlangError ->
      Enum.flat_map(ranges, fn {start, stop} ->
        lang
        |> ts_query_nif(binary_part(text, start, stop - start), query)
        |> Enum.map(fn {cap, s, e} -> {cap, s + start, e + start} end)
      end)
  end

  @doc false
  def ts_query_ranges_nif(_lang, _text, _ranges, _query),
    do: :erlang.nif_error(:nif_not_loaded)

  def ts_langs, do: :erlang.nif_error(:nif_not_loaded)

  @doc "dlopen a grammar library and register it: \"ok\" | \"error: ...\"."
  def ts_load_grammar(_name, _lib_path, _highlights), do: :erlang.nif_error(:nif_not_loaded)

  # stateful parser resource (incremental fontification; owned by a Buffer)
  @doc "Parser resource for a language, or nil if unknown."
  def ts_state_new(_lang), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Feed one edit into the held tree (byte offsets + row/byte-col points)."
  def ts_state_edit(_res, _sb, _oeb, _neb, _sr, _sc, _oer, _oec, _ner, _nec),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Drop the held tree — next highlight is a full reparse."
  def ts_state_reset(_res), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Parse (incrementally if possible) and return highlight spans."
  def ts_state_highlight(_res, _text), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Fork the held tree for background fontification. The parser locks are independent."
  def ts_state_fork(_res, _lang), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Parse with full context and return only captures intersecting START..STOP."
  def ts_state_highlight_range(_res, _text, _start, _stop), do: :erlang.nif_error(:nif_not_loaded)

  @doc "ts_node against the held tree — a walk, not a parse."
  def ts_state_node(_res, _text, _kind, _start, _stop, _op),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Every named child of one node: [{kind, start, stop}]."
  def ts_state_children(_res, _text, _kind, _start, _stop),
    do: :erlang.nif_error(:nif_not_loaded)
end
