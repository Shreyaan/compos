defmodule Compos.Ui.AgentTranscript do
  @moduledoc """
  The agent transcript block list, isolated in a LiveComponent.

  The isolation is the mechanism: on every patch the LiveView client
  rebuilds the whole view's HTML and walks the whole DOM against it.
  With the transcript inline, one keystroke in the input row walked
  every block of the conversation, and the walk grew with the chat.
  As a component with unchanged assigns, the diff ships a skip
  placeholder instead, and the client never enters this subtree.

  The parent passes `blocks` from its decorate cache, so the list is
  reference-equal between input edits and only changes when the block
  model changes. Events here carry no `phx-target`: they go to the
  parent LiveView, which owns every handler.
  """
  use Phoenix.LiveComponent
  import Compos.Ui.ComposML, only: [sigil_M: 2]

  def composml(assigns) do
    ~M"""
    <c-transcript
      id={"ag-scroll-#{@win}"}
      class={"ag-scroll ag-verbosity-#{@verbosity}"}
      verbosity={@verbosity}
      buffer={@buf}
      follow-tail={to_string(@stick)}
      phx-hook={if !assigns[:peek], do: "AgentScroll"}
      data-buf={@buf}
      data-win={@win}
      data-stick={to_string(@stick)}
      data-scroll-top={@scroll_top}
      data-scroll-anchor={@scroll_anchor}
      data-scroll-offset={@scroll_offset}
    >
      <%= for {b, block_index} <- Enum.with_index(@blocks) do %>
        <%= case b.kind do %>
          <% :user -> %>
            <c-user author="user" kind={b.kind} data-ag-index={block_index} class="ag-user"><c-label class="ag-label">YOU</c-label><c-message-body class="ag-user-text">{b.text}</c-message-body></c-user>
          <% :queued -> %>
            <c-user author="user" kind={b.kind} data-ag-index={block_index} class="ag-user ag-queued"><c-label class="ag-label">YOU</c-label><c-message-body class="ag-user-text">{b.text}</c-message-body></c-user>
          <% :prose -> %>
            <c-agent author="assistant" kind={b.kind} data-ag-index={block_index} class="ag-prose">{Phoenix.HTML.raw(b.html)}</c-agent>
          <% :thought -> %>
            <details data-ag-index={block_index} class="ag-thought"><summary>thought</summary><c-group class="ag-thought-text">{b.text}</c-group></details>
          <% :tool -> %>
            <c-toolcall call={b.id} name={b.name} state={b.status}>
            <details data-ag-index={block_index} class={"ag-tool #{b.status}"} open={b.open}>
              <summary
                phx-click="agent_card"
                phx-value-win={@win}
                phx-value-id={b.id}
                aria-label={"#{b.verb} #{b.title}, #{b.status}. Toggle call details"}
                onclick="event.preventDefault()"
              >
                <c-text class="ag-chevron" aria-hidden="true">›</c-text>
                <c-text class={"ag-dot #{b.status}"}></c-text>
                <c-text :if={b.verb not in [nil, "", "tool", "mcp", "other"]} class="ag-verb ag-kind">{b.verb}</c-text>
                <c-text class="ag-summary-copy">
                  <c-text class="ag-title" title={b.title}><c-text class="ag-tool-name">{b.name}</c-text><c-arguments
                      :if={b.arg != ""}
                      class="ag-arg"
                    >{b.arg}</c-arguments></c-text>
                  <c-text :if={!b.open && b.preview != ""} class="ag-preview">{b.preview}</c-text>
                </c-text>
                <c-status state={b.status} :if={b.status != "done"} class={"ag-tstatus #{b.status}"}>{b.status}</c-status>
                <c-text :if={b.duration} class="ag-duration">{b.duration}</c-text>
                <c-text :if={b.tokens} class="ag-duration ag-tokens">{b.tokens}</c-text>
              </summary>
              <c-result :if={b.body != ""}><pre class="ag-body">{b.body}</pre></c-result>
            </details>
            </c-toolcall>
          <% :plan -> %>
            <c-plan data-ag-index={block_index}><pre class="ag-plan">{b.text}</pre></c-plan>
          <% :permission -> %>
            <c-permission kind={b.kind} data-ag-index={block_index} class="ag-perm">
              <c-text class="ag-perm-title">needs permission — {b.title}</c-text>
              <c-toolbar class="ag-perm-actions">
                <button
                  class="ag-btn allow"
                  phx-click="ui_cmd"
                  phx-value-win={@win}
                  phx-value-cmd="agent-permission-allow"
                >Allow</button>
                <button
                  class="ag-btn session"
                  phx-click="ui_cmd"
                  phx-value-win={@win}
                  phx-value-cmd="agent-permission-always"
                >Always</button>
                <button
                  class="ag-btn deny"
                  phx-click="ui_cmd"
                  phx-value-win={@win}
                  phx-value-cmd="agent-permission-deny"
                >Deny</button>
              </c-toolbar>
            </c-permission>
          <% :question -> %>
            <c-question data-ag-index={block_index} class="ag-question">
              <c-headline class="ag-question-title">{b.question}</c-headline>
              <c-answers class="ag-question-answers">
                <button
                  :for={answer <- b.answers}
                  class="ag-btn answer"
                  phx-click="agent_answer"
                  phx-value-win={@win}
                  phx-value-slug={b.slug}
                  phx-value-question={b.id}
                  phx-value-answer={answer}
                >{answer}</button>
              </c-answers>
              <c-hint class="ag-question-hint">Choose an answer or type another reply below.</c-hint>
            </c-question>
          <% :status -> %>
            <c-summary kind={b.kind} data-ag-index={block_index} class="ag-status"><c-label class="ag-label">SUMMARY</c-label><c-group class="ag-status-text">{b.text}</c-group></c-summary>
          <% :image -> %>
            <c-user author="user" kind={b.kind} data-ag-index={block_index} class="ag-user ag-image"><c-label class="ag-label">YOU</c-label><img class="ag-image-img" src={b.src} alt={b.name} title={b.name} loading="lazy" /></c-user>
          <% :meta -> %>
            <c-info kind={b.kind} data-ag-index={block_index} class="ag-meta">{b.text}</c-info>
        <% end %>
      <% end %>
    </c-transcript>
    """
  end

  @impl true
  def render(assigns), do: Compos.Ui.Representation.live(__MODULE__, assigns)

end
