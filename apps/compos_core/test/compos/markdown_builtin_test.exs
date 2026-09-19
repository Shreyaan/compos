defmodule Compos.MarkdownBuiltinTest do
  @moduledoc """
  The Markdown grammars are built into the tree-sitter NIF: previews and
  chat prose draw through them, so a new home has them without
  `M-x ts-install-grammar markdown`.
  """

  use ExUnit.Case, async: true

  alias Compos.Core.{Markdown, TS}

  test "the block and inline grammars are built in" do
    assert "markdown" in TS.ts_langs()
    assert "markdown-inline" in TS.ts_langs()
  end

  test "a document parses into blocks and inline nodes" do
    assert {:ok, nodes} = Markdown.parse("# Title\n\nSome *emphasis* here.\n")
    kinds = flatten(nodes) |> Enum.map(& &1.kind)
    assert :heading in kinds
    assert :emphasis in kinds
  end

  test "one query reads many ranges, in the text's own offsets" do
    text = "a *b*\n\n`c` d\n"
    caps = TS.ts_query_ranges("markdown-inline", text, [{0, 5}, {7, 12}], "(emphasis) @e (code_span) @c")
    assert caps == [{"e", 2, 5}, {"c", 7, 10}]
  end

  test "several queries share one parse" do
    text = "# T\n\n- x\n"
    assert [heads, items] =
             TS.ts_queries("markdown", text, ["(atx_h1_marker) @h", "(list_marker_minus) @m"])

    assert heads == [{"h", 0, 1}]
    assert items == [{"m", 5, 7}]
  end

  defp flatten(nodes), do: Enum.flat_map(nodes, fn n -> [n | flatten(n.children)] end)
end
