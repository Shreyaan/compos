; Merge this query into an Elixir client's injections to parse ~M bodies.
((sigil
  (sigil_name) @_sigil
  (quoted_content) @injection.content)
 (#eq? @_sigil "M")
 (#set! injection.language "composml"))
