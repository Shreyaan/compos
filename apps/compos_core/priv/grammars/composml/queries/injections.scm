(expression (expression_value) @injection.content
  (#set! injection.language "elixir")
  (#set! injection.include-children))
(directive [(expression_value) (partial_expression_value) (ending_expression_value)] @injection.content
  (#set! injection.language "elixir")
  (#set! injection.include-children)
  (#set! injection.combined))
(style_text) @injection.content
  (#set! injection.language "css")
(script_text) @injection.content
  (#set! injection.language "javascript")
(attribute (attribute_name) @_name (quoted_attribute_value (attribute_value) @injection.content)
  (#eq? @_name "style")
  (#set! injection.language "css"))
