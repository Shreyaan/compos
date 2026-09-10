defmodule Compos.Ui.ComposMLGrammarTest do
  use ExUnit.Case
  alias Compos.Core.{TS, TreeSitter}

  setup_all do
    assert "composml" in TreeSitter.load_bundled()
    assert "composml" in TS.ts_langs()
    :ok
  end

  test "every migrated template parses, including raw CSS/JS and embedded expressions" do
    files = Path.wildcard(Path.expand("../../../lib/compos/ui/*.ex", __DIR__))
    assert length(files) > 10

    for file <- files do
      Macro.prewalk(Code.string_to_quoted!(File.read!(file)), fn
        {:sigil_M, _, [{:<<>>, _, [source]}, _]} = ast ->
          assert TS.ts_query_nif("composml", source, "(ERROR) @error") == [], file
          ast

        ast ->
          ast
      end)
    end
  end

  test "semantic queries locate modelines without reading CSS classes" do
    source = ~s(<c-window><c-modeline>buffer</c-modeline></c-window>)
    query = ~S|(tag (start_tag name: (semantic_name) @name) (#eq? @name "c-modeline")) @modeline|
    captures = TS.ts_query_nif("composml", source, query)

    assert Enum.any?(captures, fn {name, from, to} ->
             name == "modeline" and
               binary_part(source, from, to - from) == "<c-modeline>buffer</c-modeline>"
           end)
  end

  test "incremental edits retain structure and recover after an incomplete tag" do
    parser = TS.ts_state_new("composml")
    source = "<c-modeline>one</c-modeline>"
    assert TS.ts_state_highlight(parser, source) != []
    TS.ts_state_edit(parser, 12, 15, 15, 0, 12, 0, 15, 0, 15)
    edited = "<c-modeline>two</c-modeline>"
    assert TS.ts_state_highlight(parser, edited) == TS.ts_highlight("composml", edited)
    TS.ts_state_reset(parser)
    TS.ts_state_highlight(parser, "<c-modeline")
    TS.ts_state_reset(parser)
    assert TS.ts_state_highlight(parser, source) == TS.ts_highlight("composml", source)
  end

  test "bare filesystem nouns support semantic structural queries" do
    source = ~s(<directory path="/tmp"><file kind="directory"><filename>transcripts</filename><modified mtime="0">Jan 1</modified></file></directory>)
    query = ~S|(tag (start_tag name: (semantic_name) @name)) @element|
    captures = TS.ts_query_nif("composml", source, query)
    names = for {"name", from, to} <- captures, do: binary_part(source, from, to - from)
    assert Enum.sort(names) == Enum.sort(~w(directory file filename modified))
    assert TS.ts_query_nif("composml", source, "(ERROR) @error") == []
  end

  test "quoted braces and raw CSS do not corrupt structural parsing" do
    source =
      ~S|<c-text title={inspect(%{a: "}"})}>ok</c-text><style>c-text::before { content: "<c-window>"; }</style>|

    assert TS.ts_query_nif("composml", source, "(ERROR) @error") == []
    assert [{"css", _, _}] = TS.ts_query_nif("composml", source, "(style_text) @css")
  end
end
