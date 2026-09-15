# Prompt composition

Prompt composition is a public architectural contract. Raw feature fragments
are grouped into six stable semantic sections before they reach an LLM call.

`C-c b i` opens the six sections as switches:

1. `identity` — what compos is.
2. `general` — quiet-editor behavior, discovery, chat role, tools, and task scope.
3. `scheme` — the Scheme API and Scheme authoring guidance.
4. `reading` — blocks, outlines, tree-sitter, and narrow reads.
5. `code` — code reading, editing, and versioning.
6. `context` — how to fetch the current group and visible context.

Toggle any number, then press `x` once to apply them. `a` selects all, `n`
selects none, and `C-g` discards the draft. `chat-show-prompt` marks the live
composition with `●` and `○`. Saved LLM bundles record disabled section names.
Each bundle keeps the shortcut key assigned on its first save. Updates,
reordering, and restarts do not change it. New sections default on.

## Sources and grouping

Checked-in standing guidance lives as plain text in `priv/prompts/`.
`priv/editor.scm` defines the stable chat preamble and code-edit protocol.
Feature packages can add focused, named fragments with `prompt-part-set!`.

`priv/packages/prompts.scm` owns the raw-fragment-to-section mapping, the six
section order, the canonical join, selection, snapshots, and inspection. A raw
fragment can move inside the implementation without changing the preset UI.
Unknown mode fragments fall into `general`; `code-agent` belongs to `code`.

`chat-preamble` is not a second prompt. It is one raw fragment inside `general`.
The edit protocol and `code-instructions` form the `code` fragment.

## Direct API turns

At the start of every direct API turn, `Agent.send_prompt` asks
`Compos.Core.Agent.Backend.context/2` for context. The registered Scheme closure
is `chat-thread-context` in `priv/packages/chat.scm`.

`chat-system-prompt-parts` returns the selected semantic sections.
`chat-thread-context` joins them with `prompt-parts-text` and places the result in
the request's `system` field. The first send freezes the section bodies and
selection in `chat-prompt-snapshot`; later direct turns reuse that snapshot.
Snapshot writes hold an immutable buffer reference before composing sections.
A rename during composition therefore keeps the snapshot on the same chat.
Direct turns, ACP setup, and explicit prompt freezing use this rule.

## ACP sessions

`agent-system-prompt-parts` returns the same selected six sections for ACP.
`agent-config-with-system-parts` appends each section through
`_meta.systemPrompt.append` when the session starts. ACP tools and prompts are
fixed for that session. A connector or preset change restarts or reattaches it.

The direct and ACP lanes must express the same capabilities even though their
protocols have different lifecycles. A prompt change is incomplete until both
lanes and the inline `M-o` session path are checked.

## Context and cache stability

The system prompt contains no generated workspace or group-member list.
`priv/prompts/chat-context.txt` is static. It tells the agent to call
`(chat-context)` at the start of a task and again when the user's working context
changes. That result supplies the current chat, group members, companions,
roles, workspace directory, visible editor context, and prompt state.

Changing a group's members therefore does not change the system-prompt bytes or
invalidate the cache. Buffer contents, names, the newest user request, tool
results, and other changing material belong in messages or tool results.

## Mode fragments

Modes inject named raw fragments with `prompt-part-set!` and remove them with
`prompt-part-remove!`. The ordered `prompt-parts` buffer-local holds this derived
state. Mode setup must rebuild it after restore or reload.

`chat-mode` enables `code-agent-mode` during setup because every chat is an
agent surface. `code-agent-mode` owns the `code-agent` raw fragment. Mode changes
update the prospective source, not a frozen conversation.

Run `M-x chat-refresh-prompt` to replace the snapshot from current sources. This
command intentionally breaks the direct prompt cache. It reconnects an idle ACP
session immediately and defers a busy ACP reconnect until the next turn.

## Quiet editor policy

`priv/prompts/quiet-editor.txt` owns the default visible-state policy and appears
inside `general`. Agents work on named buffers without displaying or selecting
them. Display is only for an explicit presentation request.

## Inspection

`M-x chat-show-prompt` opens a read-only help page for the selected chat. It
shows the connector lane, lifecycle, the six ordered section names, byte counts,
each selected section, and the final canonical system text.

The page shows the frozen conversation prompt when one exists. Before the first
send, it shows the prospective prompt from current sources. An ACP connector can
also supply a system prompt that compos does not own.

## Change checklist

When changing prompt behavior:

1. Name the raw fragment, semantic section, and owner.
2. Keep dynamic workspace state out of the system prompt.
3. Preserve section order unless the change intentionally breaks the cache.
4. Check direct API, ACP, and inline composition paths.
5. Test presence, absence, order, idempotence, and final system text.
6. Keep secrets and large live document bodies out of standing guidance.
