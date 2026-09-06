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

  @empty_view %{prefixes: [], limit: 6, tabs: [], chips: []}

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
          fan_all: false,
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
         fan_all: false,
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

  # a chord: the keys go in order through the same queue. "fan" says
  # whether the chord fan stays open afterwards.
  def handle_event("keys", %{"ks" => specs} = p, socket) when is_list(specs) or is_binary(specs) do
    specs = if is_binary(specs), do: String.split(specs, " ", trim: true), else: specs
    Enum.each(specs, fn k -> if is_binary(k), do: Input.dispatch(socket.assigns.frame, k) end)
    socket = if is_boolean(p["fan"]), do: assign(socket, fan: p["fan"], fan_all: false), else: socket
    {:noreply, socket |> drain() |> refresh()}
  end

  # the chord key went down or up over nothing: the fan opens or stays
  def handle_event("fan", %{"open" => open}, socket) when is_boolean(open) do
    {:noreply, socket |> assign(fan: open, fan_all: false) |> refresh()}
  end

  # the scrim, or the key while the fan is open: never mind
  def handle_event("fan_quit", _p, socket) do
    Input.dispatch(socket.assigns.frame, "C-g")
    {:noreply, socket |> assign(fan: false, fan_all: false) |> drain() |> refresh()}
  end

  # the fan ran out of room: every binding under the prefix, as a list
  def handle_event("fan_all", _p, socket) do
    {:noreply, socket |> assign(fan_all: true) |> refresh()}
  end

  # one item of the fan. A prefix at level one latches: its key goes
  # through and the fan stays for the next slide. Anything else runs and
  # the fan closes.
  def handle_event("arc", %{"k" => key} = p, socket) when is_binary(key) do
    Enum.each(String.split(key, " ", trim: true), &Input.dispatch(socket.assigns.frame, &1))
    stays = p["lvl"] == "1" and key not in ["C-g", "M-x"]
    {:noreply, socket |> assign(fan: stays, fan_all: false) |> drain() |> refresh()}
  end

  # the composer: prose, a chord, or M-x. Scheme decides which.
  def handle_event("compose", %{"text" => text}, socket) when is_binary(text) do
    Input.run(socket.assigns.frame, fn -> Session.call_named("handheld-compose!", [text]) end)
    {:noreply, socket |> assign(fan: false, fan_all: false) |> drain() |> refresh()}
  end

  # a command by name: the modeline's bundle segment names one
  def handle_event("run", %{"cmd" => cmd}, socket) when is_binary(cmd) do
    Input.run(socket.assigns.frame, fn -> Session.call_named("run-command", [cmd]) end)
    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event("tab", %{"buf" => buf}, socket) when is_binary(buf) do
    Input.run(socket.assigns.frame, fn -> Session.call_named("switch-to-buffer!", [buf]) end)
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

    # a sheet owns the screen: the fan closes under it
    fan = socket.assigns.fan and state.minibuffer == nil and state.transient == nil

    socket =
      assign(socket,
        state: state,
        leaf: leaf,
        line_cache: cache,
        subscribed: subscribed,
        view: view,
        view_key: view_key,
        fan: fan,
        fan_all: socket.assigns.fan_all and fan
      )

    case fid && Editor.take_navigation(fid) do
      url when is_binary(url) -> push_event(socket, "navigate", %{url: url})
      _ -> socket
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
      {:ok, [prefixes, limit, tabs, chips]} ->
        %{
          prefixes: for([k, l] <- list(prefixes), do: %{key: str(k), label: str(l)}),
          limit: if(is_number(limit), do: max(trunc(limit), 1), else: 6),
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
          phx-click="tab"
          phx-value-buf={t.buf}
        >
          <div class="hh-tab-kind">{t.kind}</div>
          <div class="hh-tab-title">{t.label}</div>
        </div>
      </div>

      <div :if={@fan} class="hh-scrim" phx-click="fan_quit"></div>
      <.fan :if={@fan} state={@state} view={@view} fan_all={@fan_all} />

      <div id="chord-key" class={"hh-key #{if @fan, do: "on"}"}>
        <span class="hh-key-glyph">{key_glyph(@state)}</span>
        <span class="hh-key-cap">{if @fan, do: "slide", else: "hold"}</span>
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

  # the chord fan: prefixes at level one, the frame's which-key rows under
  # a pending prefix. Past the limit, one item opens the whole list.
  defp fan(assigns) do
    assigns = assign(assigns, items: fan_items(assigns.state, assigns.view, assigns.fan_all))

    ~H"""
    <div class="hh-fan">
      <%= if @fan_all do %>
        <div class="hh-fan-list">
          <div
            :for={it <- @items}
            class="hh-fan-row"
            data-arc={it.key}
            data-lvl={it.lvl}
            phx-click="arc"
            phx-value-k={it.key}
            phx-value-lvl={it.lvl}
          >
            <span class="hh-arc-key">{it.key}</span>
            <span class="hh-arc-label">{it.label}</span>
          </div>
        </div>
      <% else %>
        <div
          :for={{it, i} <- Enum.with_index(@items)}
          class={"hh-arc #{if it.key == "C-g" and it.lvl == "1", do: "quit"}"}
          style={"bottom: #{fan_bottom(i)}px"}
          data-arc={it.key}
          data-lvl={it.lvl}
          data-more={it[:more] && "1"}
          phx-click={if it[:more], do: "fan_all", else: "arc"}
          phx-value-k={it.key}
          phx-value-lvl={it.lvl}
        >
          <span class="hh-arc-key">{it.key}</span>
          <span class="hh-arc-label">{it.label}</span>
        </div>
      <% end %>
    </div>
    """
  end

  defp fan_items(%{pending: []}, view, _all) do
    Enum.map(view.prefixes, &%{key: &1.key, label: &1.label, lvl: "1"})
  end

  # one key per arc first: a nested sequence (a prefix under the prefix)
  # is reachable, but the thumb's row is for the keys that finish here
  defp fan_items(state, view, all) do
    rows =
      (state.which_key || [])
      |> Enum.map(&%{key: &1.key, label: &1.command, lvl: "2"})
      |> Enum.sort_by(fn r -> if String.contains?(r.key, " "), do: 1, else: 0 end)

    cond do
      all or length(rows) <= view.limit ->
        rows

      true ->
        shown = Enum.take(rows, view.limit - 1)
        shown ++ [%{key: "…", label: "#{length(rows) - length(shown)} more", lvl: "2", more: true}]
    end
  end

  # the first item sits just above the chord key; each next one a row up
  defp fan_bottom(i), do: 284 + i * 58

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
