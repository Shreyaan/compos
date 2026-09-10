; Names are grammar fields, never inferred from class values.
(tag (start_tag name: (semantic_name) @_name)
  (#eq? @_name "c-window")) @window
(tag (start_tag name: (semantic_name) @_name)
  (#eq? @_name "c-modeline")) @modeline
(tag (start_tag name: (semantic_name) @_name)
  (#eq? @_name "c-headerline")) @headerline
(tag (start_tag name: (semantic_name) @_name)
  (#eq? @_name "c-statusbar")) @statusbar
(tag (start_tag name: (semantic_name) @_name)
  (#match? @_name "^c-(message|user|agent|info|summary)$")) @message
(tag (start_tag name: (semantic_name) @_name)
  (#match? @_name "^c-tool-?call$")) @tool_call
(tag (start_tag name: (semantic_name) @_name)
  (#eq? @_name "c-field")) @field

(tag (start_tag name: (semantic_name) @_name)
  (#eq? @_name "directory")) @directory
(tag (start_tag name: (semantic_name) @_name)
  (#eq? @_name "file")) @directory.entry
(tag (start_tag name: (semantic_name) @_name)
  (#match? @_name "^(filename|size|modified|permissions|vcs-status)$")) @directory.field
(tag (start_tag name: (semantic_name) @_name)
  (#eq? @_name "symbol-entry")) @symbol
(tag (start_tag name: (semantic_name) @_name)
  (#eq? @_name "agenda-entry")) @agenda.entry
