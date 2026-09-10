# tree-sitter-composml

ComposML template and materialized-markup syntax. Derived from the MIT-licensed
[Phoenix HEEx grammar](https://github.com/phoenixframework/tree-sitter-heex)
at commit `5842537f734d7c12685bf27d6005313e3e5a47a0` (see LICENSE.md). Local changes preserve semantic names as
`semantic_name` nodes in the tag's `name` field, parse raw CSS/JavaScript bodies,
and keep quoted delimiters inside embedded Elixir expressions.

Generate with `tree-sitter generate --abi 14`; test with `tree-sitter test`.
The generated C parser is checked in so Compos can compile and load this grammar
through its existing bundled-grammar lifecycle without npm or network access.

`queries/semantics.scm` demonstrates structural queries independent of styling.
`queries/injections.scm` declares Elixir, CSS, and JavaScript boundaries. Editor
injection support may differ; query files do not themselves execute code.

The compiler checks matching names and vocabulary validity. Tree-sitter recovers
from incomplete syntax for editing; it is not the vocabulary or XML validator.

`integrations/elixir-injections.scm` is an Elixir-host query for `~M` bodies.
It lives outside `queries/` because it must be compiled against the Elixir grammar,
not the ComposML grammar. Bare mailbox domain names are semantic nodes too.
