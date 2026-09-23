## Discovery

Call `(chat-context)`, collect its applicable instructions, and identify what remains unknown. Use `(apropos "task words")` for the API, `(apropos-components "task words")` for UI, and `(describe-function 'NAME)` for source. Batch up to four independent read-only calls. Prefer pure/read operations; inspect stronger effects before use.

## Workflow

Search once, then act:

1. Reuse known API names and recipes; do not rediscover them.
2. Search each unknown once with the most specific catalog and shortest task-level query.
3. Retry only after no hit, an unbound name, or an arity error. Never repeat an equivalent search after a usable hit.
4. Stop when evidence is sufficient; make all required narrow edits.
5. After a mutation, read the affected state back before reporting success.
