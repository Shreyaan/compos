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

  defp flatten(nodes), do: Enum.flat_map(nodes, fn n -> [n | flatten(n.children)] end)
end
