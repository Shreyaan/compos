; Names are grammar fields, never inferred from class values.
(element (start_tag (tag_name) @_name)
  (#eq? @_name "c-window")) @window
(element (start_tag (tag_name) @_name)
  (#eq? @_name "c-modeline")) @modeline
(element (start_tag (tag_name) @_name)
  (#eq? @_name "c-headerline")) @headerline
(element (start_tag (tag_name) @_name)
  (#eq? @_name "c-statusbar")) @statusbar
(element (start_tag (tag_name) @_name)
  (#match? @_name "^c-(message|user|agent|info|summary)$")) @message
(element (start_tag (tag_name) @_name)
  (#match? @_name "^c-tool-?call$")) @tool_call
(element (start_tag (tag_name) @_name)
  (#eq? @_name "c-field")) @field

(element (start_tag (tag_name) @_name)
  (#eq? @_name "directory")) @directory
(element (start_tag (tag_name) @_name)
  (#eq? @_name "file")) @directory.entry
(element (start_tag (tag_name) @_name)
  (#match? @_name "^(filename|size|modified|permissions|vcs-status)$")) @directory.field
(element (start_tag (tag_name) @_name)
  (#eq? @_name "symbol-entry")) @symbol
(element (start_tag (tag_name) @_name)
  (#eq? @_name "agenda-entry")) @agenda.entry
