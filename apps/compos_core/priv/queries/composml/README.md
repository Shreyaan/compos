# ComposML queries

ComposML is a vocabulary, not a separate syntax or parser.

- Materialized `.composml` documents use the built-in HTML Tree-sitter parser.
- `html-semantics.scm` selects domain elements using that parser's tag nodes.
- `elixir-injections.scm` maps `~M` template bodies to the existing HEEx grammar
  in clients with language injection support and HEEx installed.
- Phoenix compiles `~M` templates; the ComposML compiler validates vocabulary.

These query files do not install a grammar or add injection support to a client.
No ComposML parser compilation is needed.
