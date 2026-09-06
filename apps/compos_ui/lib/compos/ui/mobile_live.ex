defmodule Compos.Ui.MobileLive do
  @moduledoc """
  The handheld client: one window, a composer, a tab rail, and a chord key.

  A second client of the same payload the desktop draws. It attaches a
  frame, reads `Compos.Core.Editor.render_state/1`, and forwards every
  gesture as the same `key` event the desktop sends. The chord fan is the
  frame's which-key rows. A sheet is the frame's transient or minibuffer.
  Nothing here is editor logic: `handheld.scm` decides the prefixes, the
  tabs, the chips, and what the composer does with a line of text.
  """

  use Phoenix.LiveView

  alias Compos.Core.{Editor, Events, Input, Session}
  alias Compos.Ui.EditorLive

  @empty_view %{tabs: [], chips: []}

  # the panel's sections that are not prefixes
  @families ["plain", "C-", "M-", "s-", "S-"]

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      requested = get_connect_params(socket)["frame"]
      {:ok, fid} = Editor.attach_frame(requested)
      Events.subscribe_frame(fid)
      Input.run(fid, fn -> Session.call_named("frame-attached!", []) end)

      if buffer = params["buffer"] do
        Input.run(fid, fn ->
          Session.call_named("open-buffer-link!", [buffer, line_param(params)])
        end)
      end

      socket =
        assign(socket,
          frame: fid,
          subscribed: MapSet.new(),
          line_cache: %{},
          boot_id: :persistent_term.get(:compos_boot_id, "dev"),
          fan: false,
          fan_tab: nil,
          keys: [],
          keys_key: nil,
          search: nil,
          view: @empty_view,
          view_key: nil
        )

      {:ok, refresh(socket)}
    else
      {:ok,
       assign(socket,
         frame: nil,
         state: nil,
         leaf: nil,
         subscribed: MapSet.new(),
         line_cache: %{},
         boot_id: :persistent_term.get(:compos_boot_id, "dev"),
         fan: false,
         fan_tab: nil,
         keys: [],
         keys_key: nil,
         search: nil,
         view: @empty_view,
         view_key: nil
       )}
    end
  end

  # ── input ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("key", %{"k" => spec}, socket) when is_binary(spec) do
    Input.dispatch(socket.assigns.frame, spec)
    {:noreply, socket |> drain() |> refresh()}
  end

  # a chord: the keys go in order through the same queue
  def handle_event("keys", %{"ks" => specs}, socket) when is_list(specs) or is_binary(specs) do
    specs = if is_binary(specs), do: String.split(specs, " ", trim: true), else: specs
    Enum.each(specs, fn k -> if is_binary(k), do: Input.dispatch(socket.assigns.frame, k) end)
    {:noreply, socket |> drain() |> refresh()}
  end

  # the chord key: the keys panel opens or closes. Opening fetches the
  # buffer's bindings from Scheme and lands on the pending prefix's tab
  # when one is latched.
  def handle_event("fan", %{"open" => open}, socket) when is_boolean(open) do
    socket = if open, do: load_keys(socket), else: socket
    {:noreply, socket |> assign(fan: open, search: nil) |> refresh()}
  end

  # the filter field: every command the text names, bound or not, from
  # Scheme. Empty text is the tabs again.
  def handle_event("fan_filter", %{"q" => q}, socket) when is_binary(q) do
    search =
      if String.trim(q) == "" do
        nil
      else
        leaf = socket.assigns.leaf
        fetch_search(socket.assigns.frame, leaf && leaf.buffer, q)
      end

    {:noreply, socket |> assign(search: search) |> refresh()}
  end

  def handle_event("fan_tab", %{"t" => tab}, socket) when is_binary(tab) do
    {:noreply, socket |> assign(fan_tab: tab) |> refresh()}
  end

  # the scrim, or the key while the panel is open: never mind
  def handle_event("fan_quit", _p, socket) do
    Input.dispatch(socket.assigns.frame, "C-g")
    {:noreply, socket |> assign(fan: false, search: nil) |> drain() |> refresh()}
  end

  # one row of the panel: its section and its key make the chord. A
  # section that is already the frame's pending prefix is not pressed
  # twice; a family section (plain, C-, M-) is not a key at all. A recent
  # row and a search match run by name. Every row's command joins the
  # recents.
  def handle_event("fan_run", %{"s" => section, "k" => key} = p, socket)
      when is_binary(section) and is_binary(key) do
    fid = socket.assigns.frame
    cmd = p["c"]

    if section in ["recent", "matches"] and is_binary(cmd) do
      Input.run(fid, fn -> Session.call_named("handheld-run-command!", [cmd]) end)
    else
      if is_binary(cmd),
        do: Input.run(fid, fn -> Session.call_named("handheld-note-command!", [cmd]) end)

      prefix = if section in @families, do: [], else: String.split(section, " ", trim: true)
      prefix = if socket.assigns.state.pending == prefix, do: [], else: prefix
      Enum.each(prefix ++ String.split(key, " ", trim: true), &Input.dispatch(fid, &1))
    end

    {:noreply, socket |> assign(fan: false, keys: [], search: nil) |> drain() |> refresh()}
  end

  # the composer: prose, a chord, or M-x. Scheme decides which.
  def handle_event("compose", %{"text" => text}, socket) when is_binary(text) do
    Input.run(socket.assigns.frame, fn -> Session.call_named("handheld-compose!", [text]) end)
    {:noreply, socket |> assign(fan: false) |> drain() |> refresh()}
  end

  # a command by name: the modeline's bundle segment names one
  def handle_event("run", %{"cmd" => cmd}, socket) when is_binary(cmd) do
    Input.run(socket.assigns.frame, fn -> Session.call_named("run-command", [cmd]) end)
    {:noreply, socket |> drain() |> refresh()}
  end

  # a tab is a group: Scheme switches to it and shows its chat
  def handle_event("tab", %{"buf" => id}, socket) when is_binary(id) do
    Input.run(socket.assigns.frame, fn -> Session.call_named("handheld-tab!", [id]) end)
    {:noreply, socket |> drain() |> refresh()}
  end

  # a held tab: the group's buffers, as a prompt
  def handle_event("tab_hold", %{"buf" => id}, socket) when is_binary(id) do
    Input.run(socket.assigns.frame, fn -> Session.call_named("handheld-tab-hold!", [id]) end)
    {:noreply, socket |> drain() |> refresh()}
  end

  # the point rail: a fraction of the buffer becomes a line number here,
  # and Scheme moves point to it
  def handle_event("rail", %{"frac" => frac}, socket) when is_number(frac) do
    leaf = socket.assigns.leaf

    if leaf do
      total = max(Compos.Core.Buffer.line_of(leaf.buffer, byte_size(leaf.text)) || 1, 1)
      frac = frac |> max(0.0) |> min(1.0)
      n = round(frac * (total - 1)) + 1
      Input.run(socket.assigns.frame, fn -> Session.call_named("handheld-scrub!", [n]) end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # a tap on a prompt candidate: move the selection there and accept.
  # The rows are the frame's own slice, so the distance is relative to
  # the selected row and no new primitive is needed.
  def handle_event("cand", %{"i" => i}, socket) do
    with mb when is_map(mb) <- socket.assigns.state.minibuffer,
         {i, ""} <- Integer.parse(to_string(i)) do
      rows = mb.candidates
      sel = Enum.find_index(rows, &Map.get(&1, :selected)) || 0
      key = if i > sel, do: "C-n", else: "C-p"

      for _ <- 1..abs(i - sel)//1, do: Input.dispatch(socket.assigns.frame, key)
      Input.dispatch(socket.assigns.frame, "RET")
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # the client's row count for the one window it draws
  def handle_event("viewport", %{"rows" => rows}, socket) when is_integer(rows) do
    Editor.set_total_rows(rows, socket.assigns.frame)
    {:noreply, socket |> drain() |> refresh()}
  end

  # ── the transcript's own events, as the desktop handles them ──────

  def handle_event("ui_cmd", %{"win" => win} = params, socket) do
    with {id, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Editor.set_active(id)
        Session.call_named("ui-command!", [params["cmd"] || false, params["buf"] || false])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event("agent_card", %{"win" => win, "id" => id}, socket) do
    with {wid, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Editor.set_active(wid)
        Session.call_named("agent-card-toggle!", [Editor.current_buffer(), id])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event(
        "agent_answer",
        %{"win" => win, "slug" => slug, "question" => question_id, "answer" => answer},
        socket
      ) do
    with {wid, ""} <- Integer.parse(to_string(win)),
         {qid, ""} <- Integer.parse(to_string(question_id)) do
      Input.run(socket.assigns.frame, fn ->
        Editor.set_active(wid)
        Session.call_named("agent-answer-question!", [slug, qid, answer])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event("ag_stick", %{"buf" => buf, "stick" => stick, "top" => top} = params, socket)
      when is_boolean(stick) and is_integer(top) do
    if Compos.Core.Buffer.exists?(buf) do
      Compos.Core.Buffer.set_local(buf, "agent-unstick", not stick)
      Compos.Core.Buffer.set_local(buf, "agent-scroll-top", top)
      anchor = if is_integer(params["anchor"]), do: params["anchor"], else: nil
      offset = if is_integer(params["offset"]), do: params["offset"], else: 0
      Compos.Core.Buffer.set_local(buf, "agent-scroll-anchor", anchor)
      Compos.Core.Buffer.set_local(buf, "agent-scroll-offset", offset)
    end

    {:noreply, socket}
  end

  def handle_event("block_click", %{"win" => win, "id" => id}, socket) do
    with {wid, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Editor.set_active(wid)
        Compos.Core.SchemeAPI.block_click(Editor.current_buffer(), id)
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event("preview_link", %{"win" => win, "href" => href}, socket)
      when is_binary(href) and byte_size(href) <= 2000 do
    with {id, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Session.call_named("preview-follow-link!", [id, href])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event("preview_link_to_group", %{"win" => win, "href" => href}, socket)
      when is_binary(href) and byte_size(href) <= 2000 do
    with {id, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Session.call_named("link-follow-to-group", [id, href])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:frame_change, _}, socket), do: {:noreply, socket |> drain() |> refresh()}
  def handle_info({:editor_change, _}, socket), do: {:noreply, socket |> drain() |> refresh()}
  def handle_info({:buffer_change, _, _}, socket), do: {:noreply, socket |> drain() |> refresh()}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp drain(socket) do
    receive do
      {:frame_change, _} -> drain(socket)
      {:editor_change, _} -> drain(socket)
      {:buffer_change, _, _} -> drain(socket)
    after
      0 -> socket
    end
  end

  # ── state ──────────────────────────────────────────────────────────

  defp refresh(socket) do
    fid = socket.assigns.frame
    state = Editor.render_state(fid)

    state =
      if fid && state.frame != fid do
        {:ok, ^fid} = Editor.attach_frame(fid)
        Editor.render_state(fid)
      else
        state
      end

    caret_owner = if state.minibuffer, do: nil, else: state.active

    {tree, cache} =
      EditorLive.decorate_tree(state.tree, socket.assigns.line_cache, state.faces, caret_owner)

    leaf = find_leaf(tree, state.active) || first_leaf(tree)
    leaf_id = leaf && leaf.id

    # the phone draws one window: only its cache entries live on
    cache =
      Map.filter(cache, fn
        {{_kind, id}, _} -> id == leaf_id
        {id, _} -> id == leaf_id
      end)

    subscribed =
      if connected?(socket) do
        visible = if leaf, do: MapSet.new([leaf.buffer]), else: MapSet.new()

        socket.assigns.subscribed
        |> MapSet.difference(visible)
        |> Enum.each(&Events.unsubscribe/1)

        visible
        |> MapSet.difference(socket.assigns.subscribed)
        |> Enum.each(&Events.subscribe/1)

        visible
      else
        socket.assigns.subscribed
      end

    {view, view_key} = view_for(socket, state, leaf)

    # a sheet owns the screen: the panel closes under it
    fan = socket.assigns.fan and state.minibuffer == nil and state.transient == nil

    socket =
      assign(socket,
        state: state,
        leaf: leaf,
        line_cache: cache,
        subscribed: subscribed,
        view: view,
        view_key: view_key,
        fan: fan
      )

    case fid && Editor.take_navigation(fid) do
      url when is_binary(url) -> push_event(socket, "navigate", %{url: url})
      _ -> socket
    end
  end

  # the buffer's bindings in the panel's sections, from Scheme. One call
  # per buffer and mode; the rows inside a section sort by rank, then key.
  defp load_keys(socket) do
    fid = socket.assigns.frame
    leaf = socket.assigns.leaf
    key = {leaf && leaf.buffer, leaf && leaf.mode}

    keys =
      if key == socket.assigns.keys_key and socket.assigns.keys != [] do
        socket.assigns.keys
      else
        fetch_keys(fid, leaf && leaf.buffer)
      end

    pending = Enum.join(socket.assigns.state.pending, " ")
    names = Enum.map(keys, & &1.name)

    tab =
      cond do
        pending != "" and pending in names -> pending
        socket.assigns.fan_tab in names -> socket.assigns.fan_tab
        true -> List.first(names)
      end

    assign(socket, keys: keys, keys_key: key, fan_tab: tab)
  end

  defp fetch_keys(nil, _buf), do: []
  defp fetch_keys(_fid, nil), do: []

  defp fetch_keys(fid, buf) do
    case Input.run(fid, fn -> Session.call_named("handheld-keys", [buf]) end) do
      {:ok, sections} when is_list(sections) ->
        for [name, rows] <- sections do
          rows = rows |> parse_rows() |> Enum.sort_by(&{&1.rank, String.downcase(&1.key), &1.key})
          %{name: str(name), rows: rows}
        end

      _ ->
        []
    end
  rescue
    _ -> []
  end

  # the commands the filter text names, in Scheme's order: bound first
  defp fetch_search(fid, buf, _q) when is_nil(fid) or is_nil(buf), do: %{name: "matches", rows: []}

  defp fetch_search(fid, buf, q) do
    rows =
      case Input.run(fid, fn -> Session.call_named("handheld-search", [buf, q]) end) do
        {:ok, rows} when is_list(rows) -> parse_rows(rows)
        _ -> []
      end

    %{name: "matches", rows: rows}
  rescue
    _ -> %{name: "matches", rows: []}
  end

  defp parse_rows(rows) do
    for [k, cmd, doc, rank] <- list(rows) do
      %{key: str(k), command: str(cmd), doc: str(doc), rank: if(is_number(rank), do: rank, else: 2)}
    end
  end

  # what Scheme says the client shows. One call per change of the shown
  # buffer, its mode, the group, or the buffer order; nothing per keystroke.
  defp view_for(socket, state, leaf) do
    key = {leaf && leaf.buffer, leaf && leaf.mode, state.frame_group, Editor.buffer_mru()}

    if key == socket.assigns.view_key do
      {socket.assigns.view, key}
    else
      {fetch_view(socket.assigns.frame, leaf && leaf.buffer), key}
    end
  end

  defp fetch_view(nil, _buf), do: @empty_view
  defp fetch_view(_fid, nil), do: @empty_view

  defp fetch_view(fid, buf) do
    case Input.run(fid, fn -> Session.call_named("handheld-view", [buf]) end) do
      {:ok, [tabs, chips]} ->
        %{
          tabs:
            for [n, l, k, c] <- list(tabs) do
              %{buf: str(n), label: str(l), kind: str(k), current: c == true}
            end,
          chips: for([l, c] <- list(chips), do: %{label: str(l), chord: str(c)})
        }

      _ ->
        @empty_view
    end
  rescue
    _ -> @empty_view
  end

  defp list(x) when is_list(x), do: x
  defp list(_), do: []

  defp str(x) when is_binary(x), do: x
  defp str({:sym, s}), do: to_string(s)
  defp str(x), do: to_string(x)

  defp find_leaf(%{type: :leaf, id: id} = leaf, id), do: leaf
  defp find_leaf(%{type: :split, children: kids}, id), do: Enum.find_value(kids, &find_leaf(&1, id))
  defp find_leaf(_, _), do: nil

  defp first_leaf(%{type: :leaf} = leaf), do: leaf
  defp first_leaf(%{type: :split, children: [kid | _]}), do: first_leaf(kid)
  defp first_leaf(_), do: nil

  defp line_param(params) do
    case Integer.parse(to_string(params["line"] || "")) do
      {n, ""} when n > 0 -> n
      _ -> false
    end
  end

  # ── render ─────────────────────────────────────────────────────────

  @impl true
  def render(%{state: nil} = assigns) do
    ~H"""
    <div id="hh" class="hh splash" phx-hook="Handheld" data-boot={@boot_id}>
      <div class="hh-splash">compos — connecting…</div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div id="hh" class="hh" phx-hook="Handheld" data-boot={@boot_id} data-frame={@frame} data-mb={to_string(@state.minibuffer != nil)}>
      <style :if={@state.faces != %{}}><%= Phoenix.HTML.raw(Compos.Ui.FaceCSS.css(@state.faces)) %></style>
      <style :if={@state.styles != %{}}><%= Phoenix.HTML.raw(Enum.join(Map.values(@state.styles), "\n")) %></style>

      <.modeline leaf={@leaf} state={@state} />

      <div class="hh-body">
        <div
          :if={@leaf && @leaf.render_mode not in ["agent", "html", "markdown", "file", "app", "terminal"]}
          class="hh-rail"
          data-rail="1"
        >
          <span class="hh-rail-k">C-p</span>
          <span class="hh-rail-w">point</span>
          <span class="hh-rail-k">C-n</span>
          <div class="hh-rail-mark" style={"top: #{rail_top(@leaf)}%"}></div>
        </div>
        <.content leaf={@leaf} />
      </div>

      <div class={"hh-composer #{if @state.minibuffer, do: "prompting"}"}>
        <div class="hh-chips">
          <div :for={c <- @view.chips} class="hh-chip" phx-click="compose" phx-value-text={c.chord}>
            <span class="hh-chip-label">{c.label}</span>
            <span class="hh-chip-chord">{c.chord}</span>
          </div>
        </div>
        <div class="hh-input-row">
          <span class="hh-prompt">{if @state.minibuffer, do: String.trim_trailing(@state.minibuffer.prompt, " "), else: "›"}</span>
          <input
            id="composer"
            class="hh-input"
            type="text"
            autocomplete="off"
            autocorrect="off"
            autocapitalize="off"
            spellcheck="false"
            enterkeyhint="send"
            placeholder={placeholder(@leaf, @state)}
          />
          <span id="composer-send" class="hh-send">RET</span>
        </div>
        <div class={"hh-echo #{if echo_error?(@state.echo), do: "err"}"}>{@state.echo}</div>
      </div>

      <div class="hh-tabs">
        <div
          :for={t <- @view.tabs}
          class={"hh-tab #{if t.current, do: "on"}"}
          data-kind={t.kind}
          data-tab={t.buf}
          phx-click="tab"
          phx-value-buf={t.buf}
        >
          <div class="hh-tab-kind">{t.kind}</div>
          <div class="hh-tab-title">{t.label}</div>
        </div>
      </div>

      <div :if={@fan} class="hh-scrim" phx-click="fan_quit"></div>
      <.keys_panel :if={@fan} state={@state} keys={@keys} tab={@fan_tab} search={@search} />

      <div id="chord-key" class={"hh-key #{if @fan, do: "on"}"}>
        <span class="hh-key-glyph">{key_glyph(@state)}</span>
        <span class="hh-key-cap">{if @fan, do: "close", else: "keys"}</span>
      </div>

      <.sheet :if={@state.minibuffer || (@state.transient && @state.transient[:groups])} state={@state} />
    </div>
    """
  end

  defp modeline(assigns) do
    ~H"""
    <div class="hh-modeline" phx-click="run" phx-value-cmd="modeline-expand">
      <span class="hh-ml-flags">{flags(@leaf)}</span>
      <span class="hh-ml-name">{ml_name(@leaf)}</span>
      <span class="hh-ml-mode">({@leaf && @leaf.mode})</span>
      <span class="hh-spacer"></span>
      <span :if={@leaf && @leaf.modeline_info not in [nil, ""]} class="hh-ml-info">{@leaf.modeline_info}</span>
      <span :if={@state.pending != []} class="hh-ml-pending">{Enum.join(@state.pending, " ")}-</span>
    </div>
    """
  end

  defp content(%{leaf: nil} = assigns) do
    ~H"""
    <div class="hh-content"></div>
    """
  end

  defp content(%{leaf: %{render_mode: "agent"}} = assigns) do
    ~H"""
    <div class="hh-content agent-view">
      <.live_component
        :if={Map.has_key?(@leaf, :ag_blocks)}
        module={Compos.Ui.AgentTranscript}
        id={"agtx-#{@leaf.id}"}
        blocks={@leaf.ag_blocks}
        win={@leaf.id}
        buf={@leaf.buffer}
        stick={@leaf.agent.stick}
        scroll_top={@leaf.agent.scroll_top}
        scroll_anchor={@leaf.agent.scroll_anchor}
        scroll_offset={@leaf.agent.scroll_offset}
      />
      <div :for={q <- Map.get(@leaf, :ag_queued, [])} class="ag-user ag-queued ag-queued-row">
        <span class="ag-label">YOU</span>
        <div class="ag-user-text">{q}</div>
      </div>
      <div
        :if={Map.get(@leaf, :ag_activity) && @leaf.ag_activity != "disconnected"}
        class="ag-wait ag-activity"
      ><span class="hh-blink"></span> {@leaf.ag_activity} · C-g interrupts</div>
    </div>
    """
  end

  defp content(%{leaf: %{render_mode: rm}} = assigns) when rm in ["html", "markdown"] do
    ~H"""
    <div class="hh-content">
      <iframe
        :if={Map.has_key?(@leaf, :preview)}
        class="hh-preview"
        id={"prev-#{@leaf.id}"}
        srcdoc={@leaf.preview}
        sandbox="allow-same-origin"
        title={@leaf.buffer}
      ></iframe>
    </div>
    """
  end

  defp content(%{leaf: %{render_mode: "file"}} = assigns) do
    ~H"""
    <div class="hh-content">
      <iframe :if={Map.has_key?(@leaf, :file_url)} class="hh-preview" src={@leaf.file_url} sandbox="" title={@leaf.buffer}></iframe>
    </div>
    """
  end

  defp content(assigns) do
    ~H"""
    <div class="hh-content hh-lines" id={"lines-#{@leaf.id}"}>
      <div :for={ln <- Map.get(@leaf, :lines, [])} class={"hh-line #{if ln.current, do: "cur"}"} data-s={ln.start}>
        <span class="hh-linenum">{ln.num}</span>
        <span class="hh-line-text"><span :for={{txt, cls} <- ln.segs} class={cls}>{txt}</span><br :if={ln.segs == []} /></span>
      </div>
      <div :if={Map.get(@leaf, :lines, []) == []} class="hh-empty">{@leaf.buffer} · {@leaf.mode}</div>
    </div>
    """
  end

  # the keys panel: a tab per section, and the section's bindings as a
  # scrolling list. A tap on a row presses the chord. While the filter
  # field holds text, the list is the search instead: every command the
  # text names, from Scheme, and a tap runs it by name.
  defp keys_panel(assigns) do
    section = Enum.find(assigns.keys, &(&1.name == assigns.tab)) || List.first(assigns.keys)
    assigns = assign(assigns, current: section && section.name)

    ~H"""
    <div class={"hh-keys #{if @search, do: "filtering"}"} id="keys-panel">
      <div class="hh-keys-tabs">
        <span
          :for={s <- @keys}
          class={"hh-keys-tab #{if s.name == @current, do: "on"}"}
          phx-click="fan_tab"
          phx-value-t={s.name}
        >{s.name}<small>{length(s.rows)}</small></span>
        <span class="hh-spacer"></span>
        <span class="hh-keys-quit" phx-click="fan_quit">C-g</span>
      </div>
      <div class="hh-keys-filter" id="keys-filter" phx-update="ignore">
        <span class="hh-prompt">/</span>
        <input
          id="keys-filter-input"
          class="hh-input"
          type="search"
          autocomplete="off"
          autocorrect="off"
          autocapitalize="off"
          spellcheck="false"
          placeholder="type to search every command"
        />
      </div>
      <div class="hh-keys-list">
        <%= if @search do %>
          <div class="hh-keys-section" data-section="matches">
            <div class="hh-keys-section-title">matches</div>
            <.key_rows section="matches" rows={@search.rows} />
            <div :if={@search.rows == []} class="hh-empty">nothing matches</div>
          </div>
        <% else %>
          <div :for={s <- @keys} class="hh-keys-section" data-section={s.name} hidden={s.name != @current}>
            <div class="hh-keys-section-title">{s.name}</div>
            <.key_rows section={s.name} rows={s.rows} />
            <div :if={s.rows == []} class="hh-empty">nothing bound here</div>
          </div>
          <div :if={@keys == []} class="hh-empty">no bindings to show</div>
        <% end %>
      </div>
    </div>
    """
  end

  # one section's rows: the key, the command, the first doc line
  defp key_rows(assigns) do
    ~H"""
    <div
      :for={r <- @rows}
      class="hh-key-row"
      phx-click="fan_run"
      phx-value-s={@section}
      phx-value-k={r.key}
      phx-value-c={r.command}
    >
      <span class="hh-key-box">{r.key}</span>
      <div class="hh-row-main">
        <div class="hh-key-cmd">{r.command}</div>
        <div :if={r.doc != ""} class="hh-key-doc">{r.doc}</div>
      </div>
    </div>
    """
  end

  defp sheet(%{state: %{minibuffer: mb}} = assigns) when is_map(mb) do
    assigns = assign(assigns, mb: mb, split: mb_split(mb))

    ~H"""
    <div class="hh-sheet-layer">
      <div class="hh-sheet-scrim" phx-click="key" phx-value-k="C-g"></div>
      <div class="hh-sheet" role="dialog" aria-modal="true">
        <div class="hh-sheet-head">
          <span class="hh-kicker">{sheet_kicker(@state)}</span>
          <span class="hh-spacer"></span>
          <span class="hh-sheet-quit" phx-click="key" phx-value-k="C-g">C-g</span>
        </div>
        <div class="hh-sheet-title">{String.trim_trailing(@mb.prompt, ": ")}</div>
        <div class="hh-sheet-hint">{sheet_hint(@mb)}</div>
        <div class="hh-sheet-input">
          <span class="hh-prompt">›</span>
          <span class="hh-mb-input"><%= with {pre, cur, post} <- @split do %>{pre}<span class="cursor">{cur}</span>{post}<% end %></span>
          <span class="hh-spacer"></span>
          <span class="hh-count">{count_text(@mb)}</span>
        </div>
        <div class="hh-sheet-rows">
          <%= for {c, i} <- Enum.with_index(@mb.candidates) do %>
            <%= if Map.get(c, :kind) == "separator" do %>
              <div class="hh-sep">{c.label}</div>
            <% else %>
              <div class={"hh-row #{if c.selected, do: "on"}"} phx-click="cand" phx-value-i={i}>
                <span class="hh-row-box">{if c.selected, do: "●", else: ""}</span>
                <div class="hh-row-main">
                  <div class="hh-row-label">{c.label}</div>
                  <div :if={Map.get(c, :hint) not in [nil, ""]} class="hh-row-sub">{c.hint}</div>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>
        <div :if={@mb.legend != []} class="hh-sheet-legend">
          <span :for={row <- @mb.legend} class="hh-legend"><b>{row.key}</b> {row.label}</span>
        </div>
      </div>
    </div>
    """
  end

  defp sheet(%{state: %{transient: t}} = assigns) do
    assigns = assign(assigns, t: t)

    ~H"""
    <div class="hh-sheet-layer">
      <div class="hh-sheet-scrim" phx-click="key" phx-value-k="C-g"></div>
      <div class="hh-sheet" role="dialog" aria-modal="true">
        <div class="hh-sheet-head">
          <span class="hh-kicker">{if @state.pending != [], do: Enum.join(@state.pending, " ") <> " · ", else: ""}transient</span>
          <span class="hh-spacer"></span>
          <span class="hh-sheet-quit" phx-click="key" phx-value-k="C-g">C-g</span>
        </div>
        <div class="hh-sheet-title">{@t.title}</div>
        <div :if={@t[:subtitle] not in [nil, ""]} class="hh-sheet-hint">{@t.subtitle}</div>
        <div :if={@t[:chips] not in [nil, []]} class="hh-tchips">
          <span :for={chip <- @t.chips} class={"hh-tchip #{if chip.active, do: "on"}"}>{chip.label}</span>
        </div>
        <div class="hh-sheet-rows">
          <%= for group <- @t.groups do %>
            <div class="hh-group-title">{group.title}</div>
            <div
              :for={item <- group.items}
              class={"hh-trow #{if item.selected, do: "on"} #{item.behavior}"}
              phx-click="keys"
              phx-value-ks={item.key}
            >
              <span class="hh-tkey">{item.key}</span>
              <div class="hh-row-main">
                <div class="hh-trow-desc">{item.description}</div>
                <div :if={item.value != ""} class="hh-trow-value">{item.value}</div>
              </div>
              <span class="hh-chev">›</span>
            </div>
          <% end %>
          <div :if={@t[:detail]} class="hh-detail">
            <div class="hh-group-title">{@t.detail.title}</div>
            <div :for={row <- @t.detail.rows} class={"hh-detail-row #{row.tone}"}>
              <span class="hh-detail-k">{row.k}</span>
              <span class="hh-detail-v">{row.v}</span>
            </div>
            <div :if={@t.detail.note != ""} class="hh-detail-note">{@t.detail.note}</div>
          </div>
        </div>
        <div class="hh-sheet-legend">
          <%= if @t[:legend] not in [nil, []] do %>
            <span :for={row <- @t.legend} class="hh-legend" phx-click="keys" phx-value-ks={row.key}><b>{row.key}</b> {row.label}</span>
          <% else %>
            <span class="hh-legend" phx-click="key" phx-value-k="RET"><b>RET</b> invoke</span>
            <span class="hh-legend" phx-click="key" phx-value-k="C-g"><b>C-g</b> quit</span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ── small helpers ──────────────────────────────────────────────────

  defp flags(nil), do: "----"

  defp flags(leaf) do
    cond do
      leaf.read_only -> "-%%-"
      leaf.modified -> "-**-"
      true -> "----"
    end
  end

  defp ml_name(nil), do: ""
  defp ml_name(leaf), do: leaf.modeline_name || leaf.buffer

  defp rail_top(nil), do: 0

  defp rail_top(leaf) do
    total = max(Compos.Core.Buffer.line_of(leaf.buffer, byte_size(leaf.text)) || 1, 1)
    line = max(Map.get(leaf, :line) || 1, 1)
    if total <= 1, do: 0, else: round((line - 1) / (total - 1) * 100)
  end

  defp key_glyph(%{pending: []}), do: "C-"
  defp key_glyph(%{pending: pending}), do: Enum.join(pending, " ")

  defp placeholder(_leaf, %{minibuffer: mb}) when is_map(mb), do: "type to narrow · RET accepts"
  defp placeholder(%{render_mode: "agent"}, _state), do: "ask, instruct, or type a chord"
  defp placeholder(%{buffer: buf}, _state), do: "ask about #{buf} · or a chord"
  defp placeholder(_, _), do: "prose, a chord, or M-x"

  defp echo_error?(echo) when is_binary(echo),
    do: echo == "Quit" or String.ends_with?(echo, "is undefined") or String.starts_with?(echo, "No ")

  defp echo_error?(_), do: false

  defp sheet_kicker(%{pending: [_ | _] = pending}), do: Enum.join(pending, " ")
  defp sheet_kicker(%{minibuffer: %{style: style}}) when is_binary(style), do: style
  defp sheet_kicker(_), do: "prompt"

  defp sheet_hint(%{style: "question"}), do: "y answers yes · n answers no · C-g quits"
  defp sheet_hint(%{style: "filter"}), do: "type to narrow · empty removes it · RET keeps it"
  defp sheet_hint(%{completing: true}), do: "Tap a row to take it, or type to narrow."
  defp sheet_hint(_), do: "Type in the field below and press RET."

  defp count_text(%{total: total, sel: sel}) when is_integer(total) and total > 0 do
    "#{min((sel || 0) + 1, total)}/#{total}"
  end

  defp count_text(_), do: ""

  defp mb_split(%{input: input, point: point}) when is_binary(input) and is_integer(point) do
    point = point |> min(byte_size(input)) |> max(0)
    rest = binary_part(input, point, byte_size(input) - point)

    case String.next_grapheme(rest) do
      nil -> {binary_part(input, 0, point), " ", ""}
      {g, post} -> {binary_part(input, 0, point), g, post}
    end
  end

  defp mb_split(mb), do: {Map.get(mb, :input, ""), " ", ""}
end
