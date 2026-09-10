defmodule Compos.Ui.ComposMLGrammarTest do
  use ExUnit.Case
  alias Compos.Core.{TS, TreeSitter}

  test "ComposML uses the built-in HTML parser and ships no parser of its own" do
    refute "composml" in TreeSitter.bundled()
    assert "html" in TS.ts_langs()
    source = ~s(<buffers><buffer name="scratch"><buffer-name>scratch</buffer-name></buffer></buffers>)
    assert TS.ts_query_nif("html", source, "(ERROR) @error") == []
  end

  test "semantic queries identify domain elements through ordinary HTML tag nodes" do
    source = ~s(<c-window><c-modeline>buffer</c-modeline><directory><file><filename>notes</filename></file></directory></c-window>)
    query = File.read!(Application.app_dir(:compos_core, "priv/queries/composml/html-semantics.scm"))
    captures = TS.ts_query_nif("html", source, query)
    for expected <- ["window", "modeline", "directory", "directory.entry", "directory.field"] do
      assert Enum.any?(captures, fn {name, _, _} -> name == expected end)
    end
  end
end
