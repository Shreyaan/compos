defmodule Compos.Ui.EditorLive do
  @moduledoc """
  The window: renders the tiling window tree per line (numbers, hl-line,
  cursor/region spans), modelines, which-key, the vertico-style minibuffer and
  echo area; forwards every keystroke to `Compos.Core.KeyDispatch`.

  Pure view — no editor logic here. Re-renders on editor-state events and on
  change events of any visible buffer (so RPC/agent edits appear live).
  """

  use Phoenix.LiveView
  import Compos.Ui.ComposML, only: [sigil_M: 2]

  alias Compos.Core.{Events, Input, Rope}
  alias Compos.Core.Markdown.Classic
  alias Compos.Scheme.Text
  alias Compos.Ui.{AppServer, LocalFile, LocalImage}

  # A normal space collapses inside an empty line, so it cannot give the
  # cursor a visible width. Keep the placeholder a non-breaking space.
  @cursor_placeholder "\u00a0"

  # the frame tab rail before Scheme has answered, and when it cannot
  @no_tabs %{tabs: [], more: 0}

  @impl true
  def mount(params, _session, socket) do
    identity = instance_identity()

    # each browser TAB is a frame (S5): the client sends its remembered
    # frame id (sessionStorage, per tab) in the connect params; unknown
    # ids are honored so the frame survives a wiped desktop.etf, absent
    # ids get a fresh frame. The id rides the payload as data-frame —
    # there is no separate frame event (S13).
    if connected?(socket) do
      requested = get_connect_params(socket)["frame"]
      {:ok, fid} = Compos.Core.Editor.attach_frame(requested)
      Events.subscribe_frame(fid)

      # the frame is new to Elixir even when Scheme has known it all along
      # (a reattach after a restart): let Scheme push back whatever this
      # frame displays — the group it stands in, for one.
      Input.run(fid, fn -> Compos.Core.Session.call_named("frame-attached!", []) end)

      # a buffer link (/b/NAME?line=N) shows that buffer in this frame.
      # What "show" means — an open buffer, a file to visit, a line to go
      # to — is Scheme's open-buffer-link!, not this view's.
      if buffer = params["buffer"] do
        Input.run(fid, fn ->
          Compos.Core.Session.call_named("open-buffer-link!", [buffer, line_param(params)])
        end)
      end

      if params["daemon-switch"] == "1" do
        Input.run(fid, fn ->
          Compos.Core.Session.eval("(when (boundp 'daemon-arrived!) (daemon-arrived!))")
        end)
      end

      socket =
        assign(socket,
          frame: fid,
          subscribed: MapSet.new(),
          line_cache: %{},
          tabs: @no_tabs,
          tabs_key: nil,
          wk_timer: nil,
          wk_shown: false,
          wk_pending: [],
          boot_id: :persistent_term.get(:compos_boot_id, "dev"),
          instance_name: identity.name,
          instance_accent: identity.accent
        )

      {:ok, refresh(socket)}
    else
      # no frame, no editor state: the static mount is a splash (S14)
      {:ok,
       assign(socket,
         frame: nil,
         state: nil,
         subscribed: MapSet.new(),
         line_cache: %{},
         tabs: @no_tabs,
         tabs_key: nil,
         boot_id: :persistent_term.get(:compos_boot_id, "dev"),
         instance_name: identity.name,
         instance_accent: identity.accent
       )}
    end
  end

  # drain before refresh: the dispatch above already broadcast its change
  # notifications to this process (Events sends before the GenServer replies),
  # so without the drain every keystroke rendered twice — once here, once in
  # handle_info
  @impl true
  def handle_event("key", %{"k" => spec}, socket) do
    Input.dispatch(socket.assigns.frame, spec)
    {:noreply, socket |> drain() |> refresh()}
  end

  # an intent from the browser's text pipeline (beforeinput): what the user
  # meant, as an inputType, a byte range, and text. KeyDispatch decides
  # whether it is a key; Scheme decides what a range means.
  def handle_event("intent", %{"type" => type, "from" => from, "to" => to} = p, socket)
      when is_binary(type) and is_integer(from) and is_integer(to) do
    text = if is_binary(p["text"]), do: p["text"], else: ""
    # The caret's own byte, and the buffer version it was measured against.
    # Both are only about the window the reader is in: a caret measured in
    # some other window names a byte in some other buffer, and the edit
    # lands in the active one. Anything else keeps the old rule.
    own? = safe_int(p["win"]) == Compos.Core.Editor.active_window(socket.assigns.frame)
    at = if own? and is_integer(p["at"]), do: p["at"], else: -1
    v = if own? and is_integer(p["v"]), do: p["v"], else: -1

    Input.run(socket.assigns.frame, fn ->
      Compos.Core.KeyDispatch.handle_intent(type, from, to, text, at, v)
    end)

    {:noreply, socket |> drain() |> refresh()}
  end

  # Cross the DOM slice boundary against the versioned buffer, then recenter.
  def handle_event("edge_motion", %{"win" => win, "point" => point, "v" => version,
                                    "dir" => dir, "count" => count} = p, socket)
      when is_integer(point) and point >= 0 and dir in [-1, 1] and
             is_integer(count) and count > 0 and count <= 1000 do
    Input.run(socket.assigns.frame, fn ->
      buf = Compos.Core.Editor.current_buffer()
      if safe_int(win) == Compos.Core.Editor.active_window() and
           version == Compos.Core.Buffer.version(buf) do
        Compos.Core.Buffer.goto(buf, point)
        if p["extend"] == true and is_integer(p["mark"]) and p["mark"] >= 0 do
          Compos.Core.Buffer.set_mark(buf, p["mark"])
        end
        Compos.Core.Session.call_named("visual-edge-move!", [dir, p["extend"] == true, count])
      end
    end)
    {:noreply, socket |> drain() |> refresh()}
  end

  # what the browser measured: round trips, patches, paints, long tasks.
  # The rows go to the collector and nothing renders: this is a report,
  # not an edit.
  def handle_event("telemetry", %{"rows" => rows}, socket) when is_list(rows) do
    Compos.Core.Telemetry.browser(rows, socket.assigns[:frame])
    {:noreply, socket}
  end

  # the native selection of an editable surface, as bytes: a click, a drag,
  # a double-click, or the answer to a select request. Point is the focus
  # end; the mark is the anchor when the selection is not collapsed.
  # A selection report is a caret motion in the selected window. A click
  # selects a window through "mouse" before its caret is reported, so a
  # report for any other window is stray: the browser's selection lives
  # in the last editable buffer, and a patch that nudges it - a popup
  # opening, a scroll beside it - reported a move nobody made, and the
  # server followed it there. Dropped.
  def handle_event("sel", %{"win" => win, "point" => point} = p, socket)
      when is_integer(point) and point >= 0 do
    with id when is_integer(id) <- safe_int(win),
         true <- id == Compos.Core.Editor.active_window(socket.assigns.frame) do
      Input.run(socket.assigns.frame, fn ->
        buf = Compos.Core.Editor.current_buffer()

        if Compos.Core.Buffer.exists?(buf) and
             (not Map.has_key?(p, "v") or p["v"] == Compos.Core.Buffer.version(buf)) do
          mark = if is_integer(p["mark"]) and p["mark"] != point, do: p["mark"], else: nil
          # a keyboard motion keeps the mark (the region follows point, as
          # in Emacs); a click or a drag says what the mark is
          unless mark == nil and p["keep"] == true do
            Compos.Core.Buffer.set_mark(buf, mark)
          end

          Compos.Core.Buffer.goto(buf, point)

          # a client that reports its caret can be asked to move it: the
          # visual-line commands take the browser's layout from here on,
          # and a headless buffer keeps the server's own motion
          if Compos.Core.Buffer.get_local(buf, "client-caret") != true do
            Compos.Core.Buffer.set_local(buf, "client-caret", true)
          end
        end
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # one handler for every click that runs a command: a transcript button
  # sends a command name, the modeline-info segment sends its buffer.
  # The Scheme gate ui-command! holds the whitelist — no policy here.
  def handle_event("ui_cmd", %{"win" => win} = params, socket) do
    with {id, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Compos.Core.Editor.set_active(id)

        Compos.Core.Session.call_named("ui-command!", [
          params["cmd"] || false,
          params["buf"] || false
        ])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # a tool card's summary: toggle its one open-state (S6) — the chat
  # local drives this view, the plain view's fold, and save/restore
  # a click on the frame tab rail: stand in that group. The chip that
  # counts the groups the rail left out opens the board instead.
  def handle_event("frame_tab", %{"id" => id}, socket) when is_binary(id) and id != "" do
    Input.run(socket.assigns.frame, fn ->
      Compos.Core.Session.call_named("frame-tab!", [id])
    end)

    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event("frame_tab", _params, socket) do
    Input.run(socket.assigns.frame, fn ->
      Compos.Core.Session.call_named("run-command", ["groups"])
    end)

    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event("agent_card", %{"win" => win, "id" => id}, socket) do
    with {wid, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Compos.Core.Editor.set_active(wid)

        Compos.Core.Session.call_named("agent-card-toggle!", [
          Compos.Core.Editor.current_buffer(),
          id
        ])
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
        Compos.Core.Editor.set_active(wid)
        Compos.Core.Session.call_named("agent-answer-question!", [slug, qid, answer])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # the transcript follow flag and reader position (S7): runtime locals,
  # so a refresh keeps the reader's place and a restart resets to follow
  def handle_event("ag_stick", %{"buf" => buf, "stick" => stick, "top" => top} = params, socket)
      when is_boolean(stick) and is_integer(top) do
    if Compos.Core.Buffer.exists?(buf) do
      # inverted on purpose: the cleared (#f) local must mean "follow"
      Compos.Core.Buffer.set_local(buf, "agent-unstick", not stick)
      Compos.Core.Buffer.set_local(buf, "agent-scroll-top", top)

      anchor = if is_integer(params["anchor"]), do: params["anchor"], else: nil
      offset = if is_integer(params["offset"]), do: params["offset"], else: 0
      Compos.Core.Buffer.set_local(buf, "agent-scroll-anchor", anchor)
      Compos.Core.Buffer.set_local(buf, "agent-scroll-offset", offset)
    end

    {:noreply, socket}
  end

  # clicking a block that carries a click id. The id is the mode's own
  # word; the view hands it back and knows nothing else. diff-mode
  # registered the handler with block-on-click!.
  def handle_event("block_click", %{"win" => win, "id" => id}, socket) do
    with {wid, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Compos.Core.Editor.set_active(wid)
        Compos.Core.SchemeAPI.block_click(Compos.Core.Editor.current_buffer(), id)
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # a client-scrolled window reporting its pixel offset (S1) — a passive
  # mirror into the leaf, so refresh and restart give the place back
  def handle_event("cscroll", %{"win" => win, "top" => top}, socket) when is_integer(top) do
    with id when is_integer(id) <- safe_int(win) do
      Compos.Core.Editor.set_client_top(id, top, socket.assigns.frame)
    end

    {:noreply, socket}
  end

  # a client's JS failure, reported by the root hook: one line in *Messages*
  def handle_event("client_error", %{"m" => m}, socket) when is_binary(m) do
    Compos.Core.Session.call_named("message", ["browser: " <> String.slice(m, 0, 500)])
    {:noreply, socket}
  end

  def handle_event("viewport", %{"rows" => rows}, socket) when is_integer(rows) do
    Compos.Core.Editor.set_total_rows(rows, socket.assigns.frame)
    {:noreply, socket |> drain() |> refresh()}
  end

  # per-window row counts: line height varies per buffer (per-buffer styles),
  # so the client measures each window against its own lines
  def handle_event("win_rows", %{"rows" => rows}, socket) when is_map(rows) do
    parsed =
      for {id, n} <- rows, is_integer(n), id_int = safe_int(id), into: %{}, do: {id_int, n}

    Compos.Core.Editor.set_window_rows(parsed, socket.assigns.frame)
    {:noreply, socket |> drain() |> refresh()}
  end

  # per-window column counts: the table views lay out in characters, so
  # the client measures its own font and says how many fit
  def handle_event("win_cols", %{"cols" => cols}, socket) when is_map(cols) do
    parsed =
      for {id, n} <- cols, is_integer(n), id_int = safe_int(id), into: %{}, do: {id_int, n}

    if Compos.Core.Editor.set_window_cols(parsed, socket.assigns.frame) do
      # a window that changed width is a window configuration change: the
      # editor says so, and Scheme decides what has to be drawn again
      Compos.Core.Session.eval("(when (boundp 'window-config-changed!) (window-config-changed!))")

      {:noreply, socket |> drain() |> refresh()}
    else
      {:noreply, socket}
    end
  end

  # per-window wrap maps: where the client saw each visual row begin, as
  # source byte offsets, with the buffer version the page showed. Kept for
  # the next key; it draws nothing, so nothing is refreshed
  def handle_event("wrap_map", %{"maps" => maps}, socket) when is_map(maps) do
    parsed =
      for {id, %{"v" => v, "r" => rows}} <- maps,
          is_integer(v),
          is_list(rows),
          Enum.all?(rows, &is_integer/1),
          id_int = safe_int(id),
          is_integer(id_int),
          into: %{},
          do: {id_int, {v, rows}}

    Compos.Core.Editor.set_wrap_maps(parsed, socket.assigns.frame)
    {:noreply, socket}
  end

  # wheel scrolls the hovered window when the client identified one,
  # falling back to this frame's active window
  def handle_event("scroll", %{"lines" => lines} = params, socket) when is_integer(lines) do
    case safe_int(params["win"]) do
      win when is_integer(win) -> Compos.Core.Editor.scroll_window(win, lines)
      _ -> Compos.Core.Editor.scroll_active(lines, socket.assigns.frame)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # mouse click: select the window (policy in scheme — a chat snaps point to
  # its input region), then place point when the click hit a text line.
  # A win-only event is a window selection, not a click on text: the blur
  # relay sends one for ANY click in a preview iframe, right clicks
  # included, so it must keep the region.
  def handle_event("mouse", %{"win" => win} = params, socket) do
    with id when is_integer(id) <- safe_int(win) do
      Input.run(socket.assigns.frame, fn ->
        case params do
          %{"line" => line, "col" => col} when is_integer(line) and is_integer(col) ->
            # A click and a visual-row move take this same path, and they
            # differ only in what becomes of the mark. Clearing it here
            # unconditionally made every move a click, so the visual-line
            # handler could not extend a selection at all and had to refuse
            # the key. Where the caret goes is geometry; whether the region
            # grows is the editor's business, so it rides as a parameter.
            #
            # Extending starts a region at point when there is none — the
            # same rule `preview-goto-src!` follows for the preview.
            mark =
              if params["extend"] == true,
                do: "(unless (mark) (set-mark! (point)))",
                else: "(set-mark! #f)"

            Compos.Core.Session.eval("(begin (mouse-select-window! #{id}) #{mark})")
            Compos.Core.Editor.mouse_goto(id, line, col)

          _ ->
            Compos.Core.Session.eval("(mouse-select-window! #{id})")
        end
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # A click inside a rendered document can name a source fragment when the
  # renderer does not provide exact source offsets. HTML uses this path.
  def handle_event("preview_goto", %{"win" => win} = p, socket) do
    with id when is_integer(id) <- safe_int(win) do
      Input.run(socket.assigns.frame, fn ->
        command = if p["extend"] == true, do: "preview-select!", else: "preview-goto!"

        Compos.Core.Session.call_named(command, [
          id,
          p["before"] || "",
          p["after"] || "",
          p["wb"] || "",
          p["wa"] || "",
          count_arg(p["nth"]),
          count_arg(p["wn"]),
          dir_arg(p["dir"])
        ])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # a click or a visual-line key inside a markdown preview's iframe: the
  # hook sends the text node split at the caret, how many times that text
  # comes before it on the page, and which way the key moves. Scheme finds
  # the spot in the source.
  # a click on a link in a rendered page. The frame never follows the link
  # itself: the href comes here and Scheme says what it means (a help page's
  # source link, a URL for the reader).
  def handle_event("preview_link", %{"win" => win, "href" => href}, socket)
      when is_binary(href) and byte_size(href) <= 2000 do
    with id when is_integer(id) <- safe_int(win) do
      Input.run(socket.assigns.frame, fn ->
        Compos.Core.Session.call_named("preview-follow-link!", [id, href])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event("preview_link_to_group", %{"win" => win, "href" => href}, socket)
      when is_binary(href) and byte_size(href) <= 2000 do
    with id when is_integer(id) <- safe_int(win) do
      Input.run(socket.assigns.frame, fn ->
        Compos.Core.Session.call_named("link-follow-to-group", [id, href])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event("preview_goto_pos", %{"win" => win, "pos" => pos} = p, socket)
      when is_integer(pos) do
    with id when is_integer(id) <- safe_int(win) do
      Input.run(socket.assigns.frame, fn ->
        Compos.Core.Session.call_named("preview-goto-pos!", [id, pos, p["extend"] == true])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # drag: the native selection, mirrored into mark + point
  def handle_event(
        "mouse_sel",
        %{"win" => win, "al" => al, "ac" => ac, "fl" => fl, "fc" => fc},
        socket
      )
      when is_integer(al) and is_integer(ac) and is_integer(fl) and is_integer(fc) do
    with id when is_integer(id) <- safe_int(win) do
      Input.run(socket.assigns.frame, fn ->
        Compos.Core.Session.eval("(mouse-select-window! #{id})")
        Compos.Core.Editor.mouse_region(id, al, ac, fl, fc)
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # system clipboard: Cmd-V arrives as a browser paste event
  def handle_event("paste", %{"text" => text}, socket) when is_binary(text) do
    Input.run(socket.assigns.frame, fn ->
      Compos.Core.Session.eval("(clipboard-paste! #{scheme_string(text)})")
    end)

    {:noreply, socket |> drain() |> refresh()}
  end

  # Browsers expose pasted files as clipboard items. Keep the bytes base64
  # encoded across the LiveView event; Scheme chooses the destination and
  # inserts the document markup.
  def handle_event("paste_image", %{"data" => data, "mime" => mime}, socket)
      when is_binary(data) and is_binary(mime) do
    result =
      Input.run(socket.assigns.frame, fn ->
        Compos.Core.Session.call_named("clipboard-image-paste!", [data, mime])
      end)

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.error("image paste failed: #{inspect(reason)}")
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # Cmd-C with no native selection: reply with the region (or kill top)
  # for the client to put on the OS clipboard — what "copy" MEANS is
  # Scheme's (clipboard-copy), like paste (S12, dup #26)
  def handle_event("copy", _params, socket) do
    text =
      Input.run(socket.assigns.frame, fn ->
        case Compos.Core.Session.call_named("clipboard-copy", []) do
          {:ok, text} when is_binary(text) -> text
          _ -> ""
        end
      end)

    {:noreply,
     socket
     |> push_event("clipboard", %{text: text})
     |> drain()
     |> refresh()}
  end

  defp scheme_string(text) do
    escaped =
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    ~s{"#{escaped}"}
  end

  @impl true
  def handle_info({:frame_change, _}, socket), do: {:noreply, socket |> drain() |> refresh()}

  def handle_info(:which_key_show, socket) do
    {:noreply, socket |> assign(wk_timer: nil, wk_shown: true) |> refresh()}
  end

  def handle_info({:editor_change, _}, socket), do: {:noreply, socket |> drain() |> refresh()}
  def handle_info({:buffer_display, _}, socket), do: {:noreply, socket |> drain() |> refresh()}
  def handle_info({:buffer_change, _, _}, socket), do: {:noreply, socket |> drain() |> refresh()}

  # coalesce bursts: drain all queued change notifications, render once
  defp drain(socket) do
    receive do
      {:frame_change, _} -> drain(socket)
      {:editor_change, _} -> drain(socket)
      {:buffer_change, _, _} -> drain(socket)
      {:buffer_display, _} -> drain(socket)
    after
      0 -> socket
    end
  end

  # timed as two halves: the editor state read (a call into the Editor
  # server, which waits when a command holds it) and the decoration of
  # the window tree (this process's own work)
  defp refresh(socket) do
    t0 = System.monotonic_time(:millisecond)
    # the boot id rides every render: a hot-swapped page module bumps it,
    # and the client's boot check reloads the page when it moves
    socket = assign(socket, boot_id: :persistent_term.get(:compos_boot_id, "dev"))
    {socket, state_ms} = refresh_state(socket)
    total = System.monotonic_time(:millisecond) - t0

    :telemetry.execute(
      [:compos, :ui, :refresh],
      %{duration: total, state: state_ms, decorate: total - state_ms},
      %{frame: socket.assigns[:frame]}
    )

    socket
  end

  # A real debounce. The CSS animation only made the panel INVISIBLE for the
  # idle delay; the browser still built its 219 nodes on the first key of
  # every chord, so C-x b rendered the whole C-x panel and threw it away.
  # Holding the render back means a fast chord costs nothing and draws
  # nothing. The delay is Scheme's which-key-idle-delay, which appearance.scm
  # publishes as the 'ui face's which-key-delay.
  defp hold_which_key(%{which_key: nil} = state, socket),
    do: {state, cancel_which_key(socket)}

  defp hold_which_key(state, socket) do
    pending = Map.get(state, :pending, [])

    cond do
      # up already: it follows the pending keys without flickering. The
      # rows come from Scheme now, not with every key: a fast chord never
      # pays for them (which-key-rows walks the buffer's whole ladder)
      socket.assigns[:wk_shown] ->
        {%{state | which_key: which_key_rows(pending, socket.assigns[:frame])}, socket}

      # the delay is idle time, not time since the chord began: while the
      # panel is still held back, every further prefix key restarts it. A
      # chord typed steadily but not fast — C-x, then r — used to spend the
      # first key's leftover delay and pop the panel a breath after the
      # second key, which reads as the key having summoned it.
      socket.assigns[:wk_pending] == pending and socket.assigns[:wk_timer] ->
        {%{state | which_key: nil}, socket}

      true ->
        {%{state | which_key: nil}, arm_which_key(state, socket, pending)}
    end
  end

  # (KEY COMMAND MODIFIERS LABEL) rows from Scheme, as the panel draws them
  defp which_key_rows(pending, fid) do
    case Compos.Core.Session.call_named("which-key-rows", [pending], fid, 5_000, :ui) do
      {:ok, rows} when is_list(rows) ->
        Enum.map(rows, fn [key, command, modifiers, label] ->
          %{key: key, command: command, modifiers: modifiers, modifier_label: label}
        end)

      _ ->
        []
    end
  end

  defp arm_which_key(state, socket, pending) do
    if t = socket.assigns[:wk_timer], do: Process.cancel_timer(t)
    timer = Process.send_after(self(), :which_key_show, which_key_delay_ms(state))
    assign(socket, wk_timer: timer, wk_shown: false, wk_pending: pending)
  end

  defp cancel_which_key(socket) do
    if t = socket.assigns[:wk_timer], do: Process.cancel_timer(t)
    assign(socket, wk_timer: nil, wk_shown: false, wk_pending: [])
  end

  @which_key_default_ms 500

  defp which_key_delay_ms(state) do
    with %{} = faces <- state.faces,
         %{} = ui <- Map.get(faces, "ui"),
         value when is_binary(value) <- Map.get(ui, "which-key-delay"),
         {seconds, _} <- Float.parse(value) do
      seconds |> Kernel.*(1000) |> round() |> max(0)
    else
      _ -> @which_key_default_ms
    end
  end

  defp refresh_state(socket) do
    fid = socket.assigns[:frame]
    t0 = System.monotonic_time(:millisecond)
    state = Compos.Core.Editor.render_state(fid)

    # our frame was deleted out from under us (M-x delete-frame elsewhere,
    # RPC): render_state fell back to another frame — recreate ours fresh
    # under the same id so the client's stored id stays good
    state =
      if fid && state.frame != fid do
        {:ok, ^fid} = Compos.Core.Editor.attach_frame(fid)
        Compos.Core.Editor.render_state(fid)
      else
        state
      end

    state_ms = System.monotonic_time(:millisecond) - t0

    # While a prompt owns the keyboard the browser stops syncing the caret
    # (layouts.ex syncEditable), so a preview that moves point — imenu,
    # ripgrep, load-theme — would land invisibly in the window it came
    # from. Nothing is the native-caret surface while a prompt is up: the
    # server draws the cursor and marks the current row again, and the
    # client scrolls that row into view.
    caret_owner = if state.minibuffer, do: nil, else: state.active

    {tree, line_cache} =
      decorate_display(
        state.tree,
        previous_leaves(socket.assigns[:state] && socket.assigns.state.tree),
        socket.assigns.line_cache,
        state.faces,
        caret_owner
      )

    state = %{state | tree: tree}

    {state, socket} = hold_which_key(state, socket)

    # cache entries for windows that left the tree die with them (S15)
    ids = state.tree |> leaf_ids() |> MapSet.new()

    line_cache =
      Map.filter(line_cache, fn
        {{_kind, id}, _} -> MapSet.member?(ids, id)
        {id, _} -> MapSet.member?(ids, id)
      end)

    subscribed =
      if connected?(socket) do
        visible = state.tree |> event_buffers() |> MapSet.new()

        # a buffer that left the window set stops feeding this client (S15)
        socket.assigns.subscribed
        |> MapSet.difference(visible)
        |> Enum.each(fn name ->
          Events.unsubscribe(name)
          Events.unsubscribe_display(name)
        end)

        visible
        |> MapSet.difference(socket.assigns.subscribed)
        |> Enum.each(fn name ->
          Events.subscribe(name)
          Events.subscribe_display(name)
        end)

        visible
      else
        socket.assigns.subscribed
      end

    {tabs, tabs_key} = frame_tabs(socket, state)

    socket =
      assign(socket,
        state: state,
        subscribed: subscribed,
        line_cache: line_cache,
        tabs: tabs,
        tabs_key: tabs_key
      )

    # a command left text for this client's OS clipboard (copy-buffer-link)
    socket =
      case fid && Compos.Core.Editor.take_clipboard(fid) do
        text when is_binary(text) -> push_event(socket, "clipboard", %{text: text})
        _ -> socket
      end

    socket =
      case fid && Compos.Core.Editor.take_navigation(fid) do
        url when is_binary(url) -> push_event(socket, "navigate", %{url: url})
        _ -> socket
      end

    # a motion command asked the browser's layout to move the selection
    socket =
      case fid && Compos.Core.Editor.take_select(fid) do
        {alter, dir, gran, count} ->
          push_event(socket, "select", %{
            alter: alter,
            dir: dir,
            granularity: gran,
            count: count
          })

        {alter, dir, gran} ->
          push_event(socket, "select", %{alter: alter, dir: dir, granularity: gran, count: 1})

        _ ->
          socket
      end

    {socket, state_ms}
  end

  defp line_param(params) do
    case Integer.parse(to_string(params["line"] || "")) do
      {n, ""} when n > 0 -> n
      _ -> false
    end
  end

  defp leaf_ids(%{type: :leaf, id: id}), do: [id]
  defp leaf_ids(%{type: :split, children: children}), do: Enum.flat_map(children, &leaf_ids/1)
  defp leaf_ids(_), do: []

  defp frame_file_path(%{tree: tree, active: active}), do: active_file_path(tree, active)

  defp active_file_path(%{type: :leaf, id: id, path: path}, id)
       when is_binary(path) and path != "",
       do: path

  defp active_file_path(%{type: :split, children: children}, id),
    do: Enum.find_value(children, &active_file_path(&1, id))

  defp active_file_path(_, _), do: nil

  # The raw PTY channel owns terminal painting. Its transcript still changes
  # as a normal buffer, but those changes must not refresh the LiveView tree.
  defp event_buffers(%{type: :leaf, render_mode: "terminal"}), do: []
  defp event_buffers(%{type: :leaf, buffer: buffer}), do: [buffer]

  defp event_buffers(%{type: :split, children: children}),
    do: Enum.flat_map(children, &event_buffers/1)

  defp event_buffers(_), do: []

  @doc """
  The display list for a window tree, for another client of the same
  payload (the handheld view). ACTIVE is the window that owns the caret,
  nil while a prompt is up. Returns the decorated tree and the cache.
  """
  def decorate_tree(tree, cache, faces, active), do: decorate(tree, cache, faces, active)

  # two-level cache: the raw line split is keyed by buffer VERSION only, so
  # cursor motion never re-splits the buffer; span decoration (cursor/region/
  # hl-line) is recomputed per render but only for lines it actually touches
  defp previous_leaves(%{type: :leaf, id: id} = leaf), do: %{id => leaf}

  defp previous_leaves(%{type: :split, children: children}) do
    Enum.reduce(children, %{}, fn child, leaves -> Map.merge(leaves, previous_leaves(child)) end)
  end

  defp previous_leaves(_), do: %{}

  defp decorate_display(%{type: :split} = split, previous, cache, faces, active) do
    {children, cache} =
      Enum.map_reduce(split.children, cache, &decorate_display(&1, previous, &2, faces, active))

    {%{split | children: children}, cache}
  end

  defp decorate_display(%{type: :leaf} = leaf, previous, cache, faces, active) do
    old = previous[leaf.id]

    if old && old.buffer == leaf.buffer &&
         (Map.get(leaf, :display_updating, false) || Events.display_updating?(leaf.buffer)) do
      {old, cache}
    else
      decorate(leaf, cache, faces, active)
    end
  end

  defp decorate(%{type: :split} = split, cache, faces, active) do
    {children, cache} =
      Enum.map_reduce(split.children, cache, &decorate(&1, &2, faces, active))

    {%{split | children: children}, cache}
  end

  defp decorate(%{type: :leaf, render_mode: "terminal"} = leaf, cache, _faces, _active) do
    {Map.put(leaf, :lines, []), cache}
  end

  # preview buffers skip the line machinery entirely; the theme is baked into
  # the srcdoc (the sandboxed iframe can't see the parent's CSS vars).
  # markdown keys on point too: the preview is editable, so the reader must
  # see where the next keystroke lands. html does not — an authored
  # document gets no marker injected into it.
  defp decorate(%{type: :leaf, render_mode: rm} = leaf, cache, faces, _active)
       when rm in ["html", "markdown"] do
    pt = if rm == "markdown", do: leaf.point, else: 0
    mark = if rm == "markdown", do: leaf.mark, else: nil

    # the oembed generation moves when a tweet fetch lands, so the cached
    # placeholder misses and the card renders
    key =
      {leaf.buffer, leaf.version, rm, leaf.preview_authored, :erlang.phash2(faces), pt, mark,
       leaf.hidden_lines, :erlang.phash2(leaf.overlays), Compos.Ui.Oembed.generation(),
       Compos.Core.Buffer.get_local(leaf.buffer, "whitespace-mode"),
       csv_preview_file_key(leaf.buffer, leaf.text, rm)}

    {html, cache} =
      case cache[{:preview, leaf.id}] do
        {^key, html} -> {html, cache}
        _ -> render_preview(rm, leaf, pt, mark, faces, cache)
      end

    shown_html =
      if Map.get(leaf, :cursor_visible, true),
        do: html,
        else: html <> "<style>.pt{visibility:hidden!important}</style>"

    {Map.merge(leaf, %{lines: [], preview: shown_html}),
     Map.put(cache, {:preview, leaf.id}, {key, html})}
  end

  # an app is not rendered here at all: the app origin serves it, and the
  # window holds only the frame that points at it
  defp decorate(%{type: :leaf, render_mode: "app"} = leaf, cache, _faces, _active) do
    {Map.merge(leaf, %{lines: [], app_url: AppServer.app_url(leaf.buffer, leaf.app_gen)}), cache}
  end

  # Scheme selects browser-file-mode. The view only signs its local path and
  # gives the browser an inert frame in which to use its native media viewer.
  defp decorate(%{type: :leaf, render_mode: "file", path: path} = leaf, cache, _faces, _active)
       when is_binary(path) do
    {Map.merge(leaf, %{lines: [], file_url: LocalFile.url(path)}), cache}
  end

  # rich agent transcript: blocks (from agent.scm's block model) become
  # typed DOM — serif prose, tool cards, permission buttons. The buffer
  # text stays canonical; this is a pure view over byte ranges.
  defp decorate(
         %{type: :leaf, render_mode: "agent", agent: %{} = ag} = leaf,
         cache,
         _faces,
         _active
       ) do
    # Input edits do not change the transcript mark or block model. Reuse the
    # complete block tree so typing and RET do not scan large tool results.
    old =
      case cache[{:agent, leaf.id}] do
        %{block_cache: block_cache} = entry -> {entry, block_cache}
        _ -> {%{}, %{}}
      end

    {old_entry, old_blocks} = old
    signature = {ag.blocks, ag.open_cards, ag.mark}

    {blocks, block_cache} =
      if old_entry[:signature] == signature do
        {old_entry.blocks, old_blocks}
      else
        {rendered, block_cache} =
          ag.blocks
          |> Enum.reverse()
          |> Enum.with_index()
          |> Enum.map_reduce(%{}, fn {b, i}, acc ->
            key = agent_block_cache_key(b, ag)

            view =
              case old_blocks[i] do
                {^key, view} -> view
                _ -> ag_block(b, leaf.text, ag.open_cards)
              end

            {view, Map.put(acc, i, {key, view})}
          end)

        {Enum.reject(rendered, &is_nil/1), block_cache}
      end

    entry = %{signature: signature, blocks: blocks, block_cache: block_cache}

    {Map.merge(leaf, %{
       lines: [],
       ag_blocks: blocks,
       ag_input: ag_input(leaf, ag),
       ag_activity: Map.get(ag, :activity),
       ag_queued: Map.get(ag, :queued) || []
     }), Map.put(cache, {:agent, leaf.id}, entry)}
  end

  # rich diff: the buffer text IS the unified diff, so the cards are parsed
  # out of the same bytes the plain view shows. Only the controlled state —
  # which cards are open, git's status letters — rides the payload.
  # a generic block tree the mode composed. This clause converts plists to
  # maps and finds the buffer line point is on; it does not know what any
  # block means.
  defp decorate(%{type: :leaf, render_mode: "blocks"} = leaf, cache, _faces, _active) do
    raw = Map.get(leaf, :blocks) || []
    key = {leaf.buffer, leaf.version, :erlang.phash2(raw)}

    blocks =
      case cache[{:blocks, leaf.id}] do
        {^key, blocks} -> blocks
        _ -> Enum.map(raw, &block_view/1)
      end

    line = Compos.Core.Text.line_index(leaf.text, leaf.point) + 1

    {Map.merge(leaf, %{lines: [], blk: blocks, blk_line: line, blk_root: block_root(Map.get(leaf, :blocks_root))}),
     Map.put(cache, {:blocks, leaf.id}, {key, blocks})}
  end

  # Select source lines before fontification and segmentation. The rope in
  # the snapshot is immutable, so line offsets and text share one version.
  defp decorate(%{type: :leaf} = leaf, cache, _faces, active) do
    rope = Map.get(leaf, :rope) || Rope.new(leaf.text)
    want = if String.contains?(leaf.window_class || "", "listing-peek"),
      do: max(leaf.total_lines, 1), else: max(leaf.rows * 3 + 8, 1)
    client_scroll? = leaf.total_lines <= want
    whitespace = whitespace?(leaf)

    raw_key =
      {leaf.buffer, leaf.version, leaf.ts_lang, leaf.overlay_gen, leaf.top, want,
       leaf.hidden_lines, leaf.narrow_lines, whitespace, Compos.Ui.Oembed.generation(),
       Map.get(leaf, :fontification, [])}

    {visible, row_cache} =
      case cache[leaf.id] do
        {^raw_key, visible, row_cache} ->
          {visible, row_cache}

        old ->
          previous =
            case old do
              {_, _, rows} -> rows
              _ -> %{}
            end

          source = viewport_lines(rope, leaf, want, client_scroll?)
          build_static(leaf, source, previous, whitespace)
      end

    lines =
      visible
      |> render_pass(
        leaf.text,
        leaf.point,
        leaf.mark,
        leaf.id == active and not leaf.read_only,
        Map.get(leaf, :cursor_visible, true)
      )
      |> Enum.map(fn ln ->
        # a visible line whose successor is folded gets a fold marker
        if MapSet.member?(leaf.hidden_lines, ln.num),
          do: %{ln | segs: ln.segs ++ [{" …", "f-fold-marker"}]},
          else: ln
      end)

    leaf = Map.put(leaf, :client_scroll?, client_scroll?)
    {Map.put(leaf, :lines, lines), Map.put(cache, leaf.id, {raw_key, visible, row_cache})}
  end

  defp csv_preview_file_key(_buffer, _text, rm) when rm != "markdown", do: nil

  defp csv_preview_file_key(buffer, text, "markdown") do
    Regex.scan(~r/^[ \t]*```[ \t]*csv[^\r\n]*:tangle[ \t]+([^ \t\r\n]+)/im, text,
      capture: :all_but_first
    )
    |> Enum.map(fn [target] ->
      path = csv_preview_path(buffer, target)

      case File.stat(path) do
        {:ok, stat} -> {path, stat.size, stat.mtime}
        _ -> {path, nil}
      end
    end)
  end

  defp viewport_lines(rope, leaf, want, client_scroll?) do
    size = Rope.line_count(rope)
    {first, last} = leaf.narrow_lines || {0, size - 1}
    top = if client_scroll?, do: 0, else: leaf.top
    hidden = leaf.hidden_lines

    indices =
      cond do
        last < first ->
          []

        MapSet.size(hidden) == 0 ->
          lo = min(first + top, last + 1)
          hi = min(lo + want - 1, last)
          if hi < lo, do: [], else: Enum.to_list(lo..hi)

        true ->
          first..last
          |> Stream.reject(&MapSet.member?(hidden, &1))
          |> Stream.drop(top)
          |> Enum.take(want)
      end

    Enum.map(indices, fn i ->
      start = Rope.line_to_byte(rope, i)
      stop = Rope.line_to_byte(rope, i + 1)
      part = Rope.slice(rope, start, stop - start)

      part =
        if String.ends_with?(part, "\n"),
          do: binary_part(part, 0, byte_size(part) - 1),
          else: part

      {{part, start}, i + 1}
    end)
  end

  defp block_open?([_s, _e, "tool", id | _], open_cards), do: id in open_cards
  defp block_open?(_, _), do: false

  # A completed block is immutable in the rich chat model. Its range and
  # metadata identify its rendered value. A running tool can add body text
  # before its range closes, so the transcript mark also keys that block.
  defp agent_block_cache_key([_s, _e, "tool", _id, _title, _kind, "running" | _] = block, ag),
    do: {block, block_open?(block, ag.open_cards), ag.mark}

  defp agent_block_cache_key(block, ag),
    do: {block, block_open?(block, ag.open_cards)}

  # Prepare only selected source lines. Faces arrive asynchronously and
  # must match this snapshot. Text rendering never calls the parser.
  defp build_static(leaf, lines, previous, whitespace) do
    spans =
      display_spans(leaf, lines)
      |> Enum.with_index()
      |> Enum.map(fn {{s, e, scope}, i} -> {s, e, "ts-" <> scope, i} end)

    # A chrome attachment stands at one byte and holds zero bytes: text the
    # buffer does not hold, drawn beside the text it decorates. It rides the
    # overlay list as a zero-length range whose face starts with "chrome-".
    {chrome_raw, plain_ov} =
      Enum.split_with(leaf.overlays, fn {_s, _e, face} ->
        is_binary(face) and String.starts_with?(face, "chrome-")
      end)

    chrome = Enum.flat_map(chrome_raw, &chrome_item/1)

    ovs = Enum.map(plain_ov, fn {s, e, face} -> {s, e, "f-" <> face} end)

    # Whitespace decoration only scans the selected lines.
    ovs =
      if whitespace do
        ws =
          Enum.flat_map(lines, fn {{part, start}, _} ->
            Regex.scan(~r/ +|\t/, part, return: :index)
            |> Enum.map(fn [{s, len}] ->
              face = if binary_part(part, s, 1) == "\t", do: "f-ws-tab", else: "f-ws-space"
              {start + s, start + s + len, face}
            end)
          end)

        ovs ++ ws
      else
        ovs
      end

    ts_per_line = stab(spans, lines, fn {s, _, _, _} -> s end, fn {_, e, _, _} -> e end)
    ov_per_line = stab(ovs, lines, fn {s, _, _} -> s end, fn {_, e, _} -> e end)
    chrome_per_line = chrome_lines(chrome, lines, byte_size(leaf.text))

    {rows, {next, prepared}} =
      [lines, ts_per_line, ov_per_line, chrome_per_line]
      |> Enum.zip()
      |> Enum.map_reduce({%{}, 0}, fn {{{part, start}, num}, line_ts, line_ov, line_chrome},
                                      {next, prepared} ->
        # Absolute offsets change after an edit above this line. Segment
        # identity depends on relative ranges, not its document position.
        ts =
          line_ts
          |> Enum.sort_by(&elem(&1, 3))
          |> Enum.map(fn {s, e, cls, _} -> {s - start, e - start, cls} end)
        ov = Enum.map(line_ov, fn {s, e, cls} -> {s - start, e - start, cls} end)

        ch =
          Enum.map(line_chrome, fn {p, side, cls, text, click} ->
            {p - start, side, cls, text, click}
          end)

        key = {part, ts, ov, ch}

        {segs, prepared} =
          case Map.fetch(previous, key) do
            {:ok, segs} -> {segs, prepared}
            :error -> {line_segs(part, start, line_ts, line_ov, line_chrome), prepared + 1}
          end

        row = %{
          part: part,
          start: start,
          num: num,
          ts: line_ts,
          ov: line_ov,
          chrome: line_chrome,
          selected: Enum.any?(line_ov, fn {_, _, face} -> face == "f-select" end),
          row: row_class(line_ov, start),
          segs: segs
        }

        {row, {Map.put(next, key, segs), prepared}}
      end)

    :telemetry.execute(
      [:compos, :ui, :text_display],
      %{visible: length(rows), prepared: prepared, reused: length(rows) - prepared},
      %{buffer: leaf.buffer, version: leaf.version}
    )

    {rows, next}
  end

  defp display_spans(%{ts_lang: lang}, _) when lang in [nil, false], do: []
  defp display_spans(_, []), do: []

  defp display_spans(leaf, lines) do
    {{_, start}, _} = hd(lines)
    {{part, last}, _} = List.last(lines)
    stop = last + byte_size(part)

    found =
      Enum.find(Map.get(leaf, :fontification, []), fn {v, s, e, _} ->
        v == leaf.version and s <= start and e >= stop
      end)

    case found do
      {_, _, _, spans} ->
        spans

      nil ->
        Compos.Core.Buffer.request_fontification(leaf.buffer, leaf.version, start, stop)

        # The buffer rebases provisional faces through every edit. Keep them
        # visible until fresh faces arrive, including when an edit exposes a
        # little more text than the previous viewport covered.
        provisional =
          leaf
          |> Map.get(:fontification, [])
          |> Enum.filter(fn {_, s, e, _} -> s <= stop and e >= start end)
          |> Enum.max_by(fn {v, s, e, _} -> {min(e, stop) - max(s, start), v} end, fn -> nil end)

        case provisional do
          {_, _, _, spans} -> spans
          nil -> []
        end
    end
  end

  # One chrome overlay -> {pos, side, class, text, click}. The face string
  # is "chrome-b:CLASS:ENCODED-TEXT[:CLICK]" (before the byte) or
  # "chrome-a:..." (after it); Scheme builds it with chrome-before /
  # chrome-after. The encoded text cannot hold a bare colon, so the split
  # is unambiguous; a click id keeps every colon it carries.
  defp chrome_item({pos, _e, "chrome-b:" <> rest}), do: [chrome_parts(pos, :before, rest)]
  defp chrome_item({pos, _e, "chrome-a:" <> rest}), do: [chrome_parts(pos, :after, rest)]
  defp chrome_item(_), do: []

  defp chrome_parts(pos, side, rest) do
    case String.split(rest, ":", parts: 3) do
      [cls, text, click] -> {pos, side, cls, URI.decode(text), click}
      [cls, text] -> {pos, side, cls, URI.decode(text), nil}
      [cls] -> {pos, side, cls, "", nil}
    end
  end

  # Which line a chrome attachment stands on. A boundary byte is shared:
  # a :before attachment belongs to what follows it, an :after attachment
  # to what precedes it; an empty line takes both, and the first and last
  # lines take what would otherwise fall off the ends.
  defp chrome_lines([], lines, _size), do: List.duplicate([], length(lines))

  defp chrome_lines(chrome, lines, size) do
    Enum.map(lines, fn {{part, start}, _num} ->
      le = start + byte_size(part)

      Enum.filter(chrome, fn {pos, side, _cls, _text, _click} ->
        pos >= start and pos <= le and
          case side do
            :before -> pos < le or le == size or start == le
            :after -> pos > start or start == 0 or start == le
          end
      end)
    end)
  end

  # Emacs stops font-locking a line once the work outgrows the reading, and
  # so do we. seg_build compares every range against every cut, so a line
  # carrying thousands of ranges costs the square of them. One 3.8 MB line
  # of minified JSON pinned a LiveView on a core for good: the window never
  # painted, the process mailbox filled, and the editor read as frozen in
  # the browser while the daemon burned nine cores. Past these bounds the
  # line renders as plain text.
  @max_styled_line 20_000
  @max_line_ranges 400

  defp row_class(line_ov, start) do
    line_ov
    |> Enum.filter(fn {s, _e, cls} ->
      is_binary(cls) and s <= start and String.starts_with?(cls, "f-row-")
    end)
    |> Enum.map_join(" ", fn {_, _, cls} -> String.replace_prefix(cls, "f-", "") end)
  end

  defp whitespace?(leaf),
    do: Compos.Core.Buffer.get_local(leaf.buffer, "whitespace-mode") == true

  defp line_segs(part, start, line_ts, line_ov, chrome \\ []) do
    segs =
      if byte_size(part) > @max_styled_line or
           length(line_ts) + length(line_ov) > @max_line_ranges do
        [{part, ""}]
      else
        seg_build(part, start, line_ts, line_ov)
      end

    splice_chrome(segs, part, start, chrome)
  end

  # A chrome attachment becomes a seg whose class starts with "chrome-seg".
  # The seg renderer draws it as a zero-length island (data-len 0), so the
  # caret walks over it and its text never counts as source bytes.
  defp splice_chrome(segs, _part, _start, []), do: segs

  defp splice_chrome(segs, part, start, chrome) do
    # at one byte, what precedes draws its :after chrome before what
    # follows draws its :before chrome
    ordered =
      Enum.sort_by(chrome, fn {pos, side, _, _, _} ->
        {pos, if(side == :after, do: 0, else: 1)}
      end)

    {done, rest, _off} =
      Enum.reduce(ordered, {[], segs, 0}, fn {pos, _side, cls, text, click}, {done, rest, off} ->
        at = Text.floor_utf8(part, min(max(pos - start, 0), byte_size(part)))
        {before, tail, off} = segs_split(rest, off, at)
        {done ++ before ++ [{text, chrome_class(cls, click)}], tail, off}
      end)

    done ++ rest
  end

  # the click id rides the class the way a link target does — a seg's class
  # is its only channel — and the seg renderer takes it back off
  defp chrome_class(cls, nil), do: "chrome-seg " <> cls

  defp chrome_class(cls, click),
    do: "chrome-seg #{cls} chrome-click:#{URI.encode(click, &URI.char_unreserved?/1)}"

  # split SEGS at in-line byte AT; OFF is the byte where SEGS begins
  defp segs_split(segs, off, at), do: segs_split(segs, off, at, [])

  defp segs_split([], off, _at, acc), do: {Enum.reverse(acc), [], off}

  defp segs_split([{txt, cls} = seg | rest], off, at, acc) do
    len = byte_size(txt)

    cond do
      off + len <= at ->
        segs_split(rest, off + len, at, [seg | acc])

      off >= at ->
        {Enum.reverse(acc), [seg | rest], off}

      true ->
        cut = at - off

        {Enum.reverse([{binary_part(txt, 0, cut), cls} | acc]),
         [{binary_part(txt, cut, len - cut), cls} | rest], at}
    end
  end

  # The ranges that touch each line, in one walk. Both the ranges and the
  # lines are in increasing start order, so a range enters when a line
  # reaches it and leaves when a line starts after it ends. Filtering the
  # whole range list per line was O(lines × ranges): a 5000-line file with
  # 20000 spans spent 100 million comparisons on every version.
  defp stab(items, lines, s_at, e_at) do
    sorted = Enum.sort_by(items, s_at)

    {per_line, _} =
      Enum.map_reduce(lines, {sorted, []}, fn {{part, start}, _num}, {pending, active} ->
        le = start + byte_size(part)
        {reached, pending} = Enum.split_while(pending, fn it -> s_at.(it) < le end)
        active = Enum.filter(active ++ reached, fn it -> e_at.(it) > start end)
        {active, {pending, active}}
      end)

    per_line
  end

  defp safe_int(v) when is_integer(v), do: v

  defp safe_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  # a client that cannot name its window sends null: no window, no crash
  defp safe_int(_), do: nil

  defp count_arg(n) when is_integer(n) and n >= 0, do: n
  defp count_arg(_), do: 0
  defp dir_arg(d) when d in [-1, 0, 1], do: d
  defp dir_arg(_), do: 0

  # --- rendering -------------------------------------------------------------

  defp which_key_groups(bindings) do
    bindings
    |> Enum.chunk_by(& &1.modifiers)
    |> Enum.map(fn group ->
      first = hd(group)
      {first.modifier_label, first.modifiers, group}
    end)
  end

  # the disconnected mount is not a client: it attaches no frame and
  # renders a neutral splash — the connected mount replaces it (S14)
  def composml(%{state: nil} = assigns) do
    ~M"""
    <c-frame
      id="editor"
      class={instance_class("editor-root splash", @instance_accent)}
      style={instance_style(@instance_accent)}
      phx-hook="Keys"
      data-boot={@boot_id}
      data-instance={@instance_name}
    >
      <c-group style="display:flex;align-items:center;justify-content:center;height:100vh;opacity:.5;font-family:monospace">
        compos — connecting…
      </c-group>
    </c-frame>
    """
  end

  def composml(assigns) do
    ~M"""
    <c-frame
      id="editor"
      role="application"
      aria-label="compos editor"
      class={instance_class("editor-root", @instance_accent)}
      style={root_style(@state, @instance_accent)}
      phx-hook="Keys"
      data-boot={@boot_id}
      data-frame={@frame}
      data-instance={@instance_name}
    >
      <style :if={@state.faces != %{}}><%= Phoenix.HTML.raw(Compos.Ui.FaceCSS.css(@state.faces)) %></style>
    <style :if={@state.styles != %{}}><%= Phoenix.HTML.raw(Enum.join(Map.values(@state.styles), "\n")) %></style>
      <c-group :if={@state.workspace} class="workspace-bar" role="banner">
        <c-text class="workspace-bar-kind">WORKTREE</c-text>
        <strong :if={@state.workspace.project && @state.workspace.name}>
          {@state.workspace.project} / {@state.workspace.name}
        </strong>
        <strong :if={!(@state.workspace.project && @state.workspace.name)}>
          {@state.workspace.daemon}
        </strong>
        <c-text class="workspace-bar-port">PORT {workspace_port(@state.workspace.url)}</c-text>
        <c-text class="workspace-bar-root">{@state.workspace.root}</c-text>
        <c-text class="workspace-bar-help">C-x w new tab · C-x d switch daemon</c-text>
      </c-group>
      <.frame_header_line state={@state} tabs={@tabs} />
      <.frame_echo state={@state} />
      <c-windows class="windows" role="main">
        <.tree node={@state.tree} active={@state.active} completion={@state.completion} />
      </c-windows>
      <c-which-key :if={@state.which_key && @state.minibuffer == nil && @state.transient == nil} class="which-key mb-geom-panel">
        <c-group class="wk-title">
          <c-text>
            {Enum.join(@state.pending, " ")} —
            <c-text class="wk-count" data-total={length(@state.which_key)}>
              {length(@state.which_key)} bindings
            </c-text>
          </c-text>
          <c-text class="wk-filter" aria-live="polite">Hold a modifier · / filters commands</c-text>
        </c-group>
        <c-group class="wk-groups">
          <%= for {label, modifiers, bindings} <- which_key_groups(@state.which_key) do %>
            <section class="wk-group" data-modifiers={Enum.join(modifiers, " ")}>
              <h3 class="wk-group-title">{label}<c-text>{length(bindings)}</c-text></h3>
              <c-group class="wk-grid">
                <c-group :for={w <- bindings} class="wk-item" data-command={String.downcase(w.command)}>
                  <c-action-key class="wk-key">{w.key}</c-action-key>
                  <c-text class="wk-cmd">{w.command}</c-text>
                </c-group>
              </c-group>
            </section>
          <% end %>
          <c-group class="wk-empty" hidden>No matching commands</c-group>
        </c-group>
      </c-which-key>
      <%= if @state.minibuffer do %>
        <c-group class="mb-modal-layer">
          <c-group
            class={mb_panel_class(@state.minibuffer)}
            role="dialog"
            aria-modal="true"
            aria-label={String.trim_trailing(@state.minibuffer.prompt, ": ")}
          >
          <%= if mb_geom(@state.minibuffer) == "modal" do %>
            <c-group class="mb-head">
              <c-text class="mb-head-title">{String.trim_trailing(@state.minibuffer.prompt, ": ")}</c-text>
              <c-text class="mb-head-spacer"></c-text>
              <c-text class="mb-head-legend">
                <c-text :for={row <- palette_legend(@state.minibuffer)} class="transient-legend"><c-action-key class="transient-legend-key">{row.key}</c-action-key> {row.label}</c-text>
              </c-text>
            </c-group>
          <% else %>
            <c-group class="mb-label-row">
              <%= case Map.get(@state.minibuffer, :legend, []) do %>
                <% [_ | _] = legend -> %>
                  <c-text :for={row <- legend} class="transient-legend"><c-action-key class="transient-legend-key">{row.key}</c-action-key> {row.label}</c-text>
                <% _ -> %>
                  {label_row(@state.minibuffer)}
              <% end %>
            </c-group>
          <% end %>
          <c-group class={"mb-body #{if mb_rail_focused?(@state.minibuffer), do: "rail-focus"}"}>
            <.dynamic_tag tag_name={if Enum.any?(@state.minibuffer.candidates, &(Map.get(&1, :kind) == "symbol")), do: "symbol-list", else: "c-completions"} aria-label={@state.minibuffer.prompt} id="mb-cands" class="mb-cands" phx-hook="SelectionScroll" style={"--mb-label-w: #{@state.minibuffer.label_width}ch"}>
              <%= for c <- @state.minibuffer.candidates do %>
                <%= if Map.get(c, :kind) == "separator" do %>
                  <c-group class="mb-sep"><c-text class="mb-sep-label">{c.label}</c-text></c-group>
                <% else %>
                  <.dynamic_tag tag_name={if Map.get(c, :kind) == "symbol", do: "symbol-entry", else: "c-completion"}
                    selected={to_string(c.selected)} class={"mb-cand #{if c.selected, do: "selected"}"}
                    {if Map.get(c, :kind) == "symbol", do: symbol_attrs(c), else: []}>
                    <%= if Map.get(c, :kind) == "symbol" do %>
                      <symbol-name class={"mb-label #{candidate_face_class(c)}"}>{c.label}</symbol-name>
                      <c-text class="mb-hint"><symbol-kind>{symbol_fact(c, "kind")}</symbol-kind> · <symbol-location source={symbol_fact(c, "source")} line={symbol_fact(c, "line")}>L{symbol_fact(c, "line")}</symbol-location><%= if symbol_fact(c, "doc") != "" do %> — {symbol_fact(c, "doc")}<% end %></c-text>
                    <% else %>
                      <c-text class={"mb-label #{candidate_face_class(c)}"}>{c.label}</c-text>
                      <c-text class="mb-hint">{c.hint}</c-text>
                    <% end %>
                  </.dynamic_tag>
                <% end %>
              <% end %>
            </.dynamic_tag>
            <c-group
              :if={mb_geom(@state.minibuffer) == "modal" && mb_rail(@state.minibuffer)}
              id="mb-rail"
              class={"mb-preview mb-rail #{if mb_rail_focused?(@state.minibuffer), do: "focused"}"}
              phx-hook="SelectionScroll"
            >
              <%= with rail <- mb_rail(@state.minibuffer) do %>
                <c-group class="mb-preview-title">buffers</c-group>
                <c-group :for={row <- rail.rows} class={"mb-rail-row #{if row.selected, do: "selected"}"}>
                  <c-text class="mb-rail-name">{row.label}</c-text>
                  <c-text class="mb-rail-hint">{row.hint}</c-text>
                </c-group>
              <% end %>
            </c-group>
            <c-group
              :if={
                mb_geom(@state.minibuffer) == "modal" && !mb_rail(@state.minibuffer) &&
                  mb_preview(@state.minibuffer)
              }
              class="mb-preview"
            >
              <%= with p <- mb_preview(@state.minibuffer) do %>
                <c-group class="mb-preview-title">{p.title}</c-group>
                <c-group :for={{k, v} <- p.facts} class="mb-preview-fact">
                  <c-text class="mb-preview-k">{k}</c-text>
                  <c-text class="mb-preview-v">{v}</c-text>
                </c-group>
                <c-group :if={p.note != ""} class="mb-preview-note">{p.note}</c-group>
              <% end %>
            </c-group>
          </c-group>
          <c-group class={"mb-input-row #{if Map.get(@state.minibuffer, :prompt_sel), do: "selected"}"}>
            <c-text class="prompt">{@state.minibuffer.prompt}</c-text>
            <c-text class="mb-input"><%= with {pre, cur, post} <- mb_split(@state.minibuffer) do %>{pre}<c-cursor class="cursor">{cur}</c-cursor>{post}<% end %></c-text>
            <c-text class="mb-spacer"></c-text>
            <c-text :if={frame_file_path(@state)} class="ml-frame-path" title={frame_file_path(@state)}>{frame_file_path(@state)}</c-text>
            <c-text class="mb-count">{count_text(@state.minibuffer)}</c-text>
          </c-group>
        </c-group>
      </c-group>
      <% else %>
        <%= if @state.transient && @state.transient[:groups] do %>
          <c-minibuffer class={"mb-panel palette mb-geom-modal transient-panel #{if @state.transient[:detail], do: "with-rail"}"}>
            <c-group class="transient-head">
              <c-text class="transient-title">{@state.transient.title}</c-text>
              <c-text :if={@state.transient[:subtitle] not in [nil, ""]} class="transient-subtitle">{@state.transient.subtitle}</c-text>
              <c-text class="transient-head-spacer"></c-text>
              <c-text :if={@state.transient[:chips] not in [nil, []]} class="transient-chips">
                <c-text :for={chip <- @state.transient.chips} class={"transient-chip #{if chip.active, do: "active"}"}>{chip.label}</c-text>
              </c-text>
              <c-text :if={@state.transient[:context] not in [nil, ""]} class="transient-context">{@state.transient.context}</c-text>
            </c-group>
            <c-group class="transient-body">
              <c-group id="transient-groups" class="transient-groups" phx-hook="SelectionScroll">
                <c-group :for={column <- transient_columns(@state.transient)} class="transient-column">
                  <section :for={group <- Enum.filter(@state.transient.groups, &(&1.title in column))} class="transient-group">
                    <c-group class="transient-group-title">{group.title}</c-group>
                    <c-group
                      :for={item <- group.items}
                      class={"transient-item #{if item.selected, do: "selected"} #{item.behavior}"}
                    >
                      <c-action-key class="transient-key">{item.key}</c-action-key>
                      <c-text class="transient-description">{item.description}</c-text>
                      <c-text :if={item.value != ""} class="transient-value">{item.value}</c-text>
                    </c-group>
                  </section>
                </c-group>
              </c-group>
              <aside :if={@state.transient[:detail]} class="transient-rail">
                <c-group class="transient-rail-title">{@state.transient.detail.title}</c-group>
                <c-group :for={row <- @state.transient.detail.rows} class={"transient-rail-row #{row.tone}"}>
                  <c-text class="transient-rail-k">{row.k}</c-text>
                  <c-text class="transient-rail-v">{row.v}</c-text>
                </c-group>
                <c-group :if={@state.transient.detail.note != ""} class="transient-rail-note">{@state.transient.detail.note}</c-group>
              </aside>
            </c-group>
            <c-group class="transient-help">
              <%= if @state.transient[:legend] not in [nil, []] do %>
                <c-text :for={row <- @state.transient.legend} class="transient-legend"><c-action-key class="transient-legend-key">{row.key}</c-action-key> {row.label}</c-text>
              <% else %>
                <c-text class="transient-legend"><c-action-key class="transient-legend-key">RET</c-action-key> invoke</c-text>
                <c-text class="transient-legend"><c-action-key class="transient-legend-key">C-g</c-action-key> quit</c-text>
                <c-text class="transient-legend"><c-action-key class="transient-legend-key">↑↓</c-action-key> select</c-text>
                <c-text class="transient-legend"><c-action-key class="transient-legend-key">?</c-action-key> help</c-text>
              <% end %>
            </c-group>
          </c-minibuffer>
        <% else %>
        <% end %>
      <% end %>
    </c-frame>
    """
  end

  # The frame's header line. It carries only what stays: the wordmark, the
  # groups as tabs, and the frame's facts (global-mode-string). The frame
  # names its current group here, once; a window in that group does not
  # repeat it. A hairline holds the two halves apart. The message and the
  # key hints live in the echo area, so a message never moves a tab.
  defp frame_header_line(assigns) do
    ~M"""
    <c-statusbar class="echo-bar">
      <c-text class="ml-wordmark" title="compos">
        <img src="/images/compos-emblem-v1.png" width="15" height="15" alt="" />compos
      </c-text>
      <c-text class="ml-divider"></c-text>
      <c-tabs :if={@tabs.tabs != []} class="ml-tabs">
        <c-tab
          :for={t <- @tabs.tabs}
          class={"ml-tab #{if t.current, do: "ml-tab-on"}"}
          title={"switch to #{t.label}"}
          phx-click="frame_tab"
          phx-value-id={t.id}
        ><%= if t.segs != [] do %><c-text :for={{c, x} <- t.segs} class={c}>{x}</c-text><% else %>{t.label}<% end %></c-tab>
        <c-tab
          :if={@tabs.more > 0}
          class="ml-tab ml-tab-more"
          title="every group (C-x C-g l)"
          phx-click="frame_tab"
        >{@tabs.more} more</c-tab>
      </c-tabs>
      <c-text class="ml-rule"></c-text>
      <c-text :if={@state.modeline_extra not in ["", []]} class="ml-extra"><%= if is_binary(@state.modeline_extra) do %><c-text class="ml-attention">{@state.modeline_extra}</c-text><% else %><c-text :for={{c, t} <- @state.modeline_extra} class={c}>{t}</c-text><% end %></c-text>
    </c-statusbar>
    """
  end

  # The echo area is the frame's own bar and holds only what passes: the
  # message, a rule, then the keys that matter where you are standing. It
  # sits under every window unless echo-area-position says top.
  defp frame_echo(assigns) do
    ~M"""
    <c-statusbar class="echo-area" role="status">
      <c-echo class="echo">{@state.echo}</c-echo>
      <c-text class="ml-rule"></c-text>
      <c-key-hints class="echo-hint">
        <c-text :for={{k, v} <- header_keys()} class="ml-hint"><c-action-key>{k}</c-action-key><%= if v != "" do %><c-text class="ml-do">{v}</c-text><% end %></c-text>
      </c-key-hints>
    </c-statusbar>
    """
  end

  # The echo area's key hints. Each entry is a key and the verb it runs; an
  # empty verb draws the key alone, the way the design does for the keys
  # every Emacs user already knows.
  @header_keys [
    {"C-x C-f", ""},
    {"C-x b", ""},
    {"C-x d", ""},
    {"C-c a", "agent"},
    {"M-x", ""},
    {"C-g", ""}
  ]

  defp header_keys, do: @header_keys

  # The groups the frame modeline offers as tabs. Scheme decides which
  # ones and how many, and this asks again only when the frame's group or
  # the buffer order moved: nothing per keystroke.
  defp frame_tabs(socket, state) do
    key = {state.frame_group, Compos.Core.Editor.buffer_mru()}

    if key == socket.assigns[:tabs_key] do
      {socket.assigns[:tabs] || @no_tabs, key}
    else
      {fetch_tabs(socket.assigns[:frame]), key}
    end
  end

  defp fetch_tabs(nil), do: @no_tabs

  defp fetch_tabs(fid) do
    case Input.run(fid, fn -> Compos.Core.Session.call_named("frame-tabs", []) end) do
      {:ok, [rows, more]} when is_list(rows) ->
        %{
          tabs:
            for [id, label, current | rest] <- rows do
              %{
                id: to_string(id),
                label: to_string(label),
                current: current == true,
                # the rendered name, from the same grammar the modeline uses
                segs: ml_segs(%{modeline_name_segments: List.first(rest)})
              }
            end,
          more: if(is_number(more), do: trunc(more), else: 0)
        }

      _ ->
        @no_tabs
    end
  rescue
    _ -> @no_tabs
  end

  defp workspace_port(url) do
    case URI.parse(url) do
      %URI{port: port} when is_integer(port) -> port
      _ -> "?"
    end
  end

  defp frame_group_style(%{frame_group_color: color}) when is_binary(color) do
    if Regex.match?(~r/^#[0-9a-fA-F]{6}$/, color), do: "--frame-group-color: #{color}", else: nil
  end

  defp frame_group_style(_state), do: nil

  defp instance_identity do
    %{
      name: Application.get_env(:compos_core, :name, "compos"),
      accent: valid_accent(Application.get_env(:compos_core, :accent))
    }
  end

  defp valid_accent(color) when is_binary(color) do
    if Regex.match?(~r/^#[0-9a-fA-F]{6}$/, color), do: color, else: nil
  end

  defp valid_accent(_color), do: nil

  defp instance_style(nil), do: nil
  defp instance_style(color), do: "--instance-accent: #{color}"

  defp instance_class(base, nil), do: base
  defp instance_class(base, _color), do: base <> " instance-identified"

  defp root_style(state, accent) do
    [frame_group_style(state), instance_style(accent)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  defp window_style(node) do
    color = Map.get(node, :group_color)

    group_style =
      if is_binary(color) and Regex.match?(~r/^#[0-9a-fA-F]{6}$/, color),
        do: "--buffer-group-color: #{color}",
        else: nil

    [Map.get(node, :window_style), group_style]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join("; ")
  end

  defp symbol_fact(candidate, key), do: Map.get(Map.new(Map.get(candidate, :facts, [])), key, "")

  defp symbol_attrs(candidate), do: Enum.filter(Map.get(candidate, :facts, []), fn {key, _} -> key in ~w(name kind source line) end)

  defp candidate_face_class(%{face: face}) when is_binary(face) do
    if Regex.match?(~r/^[a-zA-Z0-9_-]+$/, face), do: "f-#{face}", else: ""
  end

  defp candidate_face_class(_candidate), do: ""

  # cursor sits at the minibuffer's point (it's a real buffer): split the
  # input into before-point, the grapheme under the cursor, and the rest
  defp mb_split(%{input: input, point: point}) do
    point = point |> min(byte_size(input)) |> max(0)
    rest = binary_part(input, point, byte_size(input) - point)

    case String.next_grapheme(rest) do
      nil -> {binary_part(input, 0, point), " ", ""}
      {g, post} -> {binary_part(input, 0, point), g, post}
    end
  end

  defp mb_split(mb), do: {mb.input, " ", ""}

  # Keep the DOM geometry in lockstep with Editor.render_minibuffer/2.  The
  # renderer includes `geometry` so a LiveView patch does not have to infer a
  # panel shape from a presentation style; the style fallback keeps an older
  # daemon and a freshly recompiled UI compatible during development.
  # The three shapes are minibuffer, panel and modal. "popup" is the name
  # panel used to wear; it is still accepted here so an older daemon and a
  # freshly recompiled UI agree during development. A popup WINDOW is a
  # different thing (display-buffer's popup action) and shares no name.
  defp mb_geom(%{geometry: geometry}) when geometry in ["minibuffer", "panel", "modal"],
    do: geometry

  defp mb_geom(%{geometry: "popup"}), do: "panel"

  defp mb_geom(mb) do
    case Map.get(mb, :style) do
      style when style in ["palette", "modal"] -> "modal"
      style when style in ["panel", "popup"] -> "panel"
      _ -> "minibuffer"
    end
  end

  defp mb_panel_class(mb) do
    case mb_geom(mb) do
      # `palette` remains the visual vocabulary for the existing large
      # completion panel; `mb-geom-modal` names its layout role.
      "modal" -> "mb-panel palette mb-geom-modal"
      "panel" -> "mb-panel mb-geom-panel"
      "minibuffer" -> "mb-panel mb-geom-minibuffer"
    end
  end

  # A question is not a completion prompt. It takes one key, so it says
  # which keys answer it, and it counts nothing.
  defp label_row(%{style: "question"} = mb),
    do: "#{String.trim_trailing(mb.prompt, " ")} · y answers yes · n answers no · C-g quits"

  # a filter narrows the list behind it; the list itself shows the count,
  # so the prompt says what the keys do and nothing more. A prompt that
  # wrote its own legend says that instead — see the label row.
  defp label_row(%{style: "filter"} = mb),
    do:
      "#{String.trim_trailing(mb.prompt, ": ")} · type to narrow · DEL widens · " <>
        "empty removes it · RET / C-g close · \\ removes filter"

  defp label_row(mb),
    do:
      "#{String.trim_trailing(mb.prompt, ": ")} · TAB completes · RET accepts · " <>
        "C-n/C-p selects · C-c C-o collects · C-g quits"

  defp count_text(%{style: "question"}), do: ""
  defp count_text(%{style: "filter"}), do: ""

  defp count_text(%{total: total, sel: sel, completing: completing} = mb) do
    cond do
      # the prompt holds the selection: RET opens this directory
      total > 0 and Map.get(mb, :prompt_sel) -> "#{total} · RET opens dir"
      total > 0 -> "#{sel + 1}/#{total}"
      completing -> "TAB completes"
      true -> "no match"
    end
  end

  # the columns Scheme decided for a transient; an older menu has none, so
  # every group stands alone
  defp transient_columns(%{columns: [_ | _] = cols}), do: cols
  defp transient_columns(%{groups: groups}), do: Enum.map(groups, &[&1.title])

  # the palette's head row legend: the prompt's own, else the completion keys
  defp palette_legend(%{legend: [_ | _] = rows}), do: rows

  defp palette_legend(_mb) do
    [
      %{key: "TAB", label: "complete"},
      %{key: "RET", label: "accept"},
      %{key: "C-n C-p", label: "select"},
      %{key: "C-c C-o", label: "collect"},
      %{key: "C-g", label: "quit"}
    ]
  end

  # The rail as a list: the prompt wrote the rows, so the view only says
  # which one is on. A prompt without a rail gets the facts panel instead.
  defp mb_rail(mb), do: Map.get(mb, :rail)

  defp mb_rail_focused?(mb) do
    case Map.get(mb, :rail) do
      %{focused: true} -> true
      _ -> false
    end
  end

  # The palette's right-hand rail: facts about the highlighted row. A row
  # brings its own facts (the prompt wrote them); a row without any shows
  # its hint. The note under the facts is the prompt's, or nothing.
  defp mb_preview(mb) do
    note = Map.get(mb, :note) || ""

    case Enum.find(mb.candidates, &Map.get(&1, :selected)) do
      nil ->
        nil

      # a row that wrote its own facts says them as they are: a group
      # card writes the whole group, and the rail is where it fits
      %{facts: [_ | _] = facts} = c ->
        %{title: c.label, facts: facts, note: note}

      %{kind: "container"} = c ->
        chips = Map.get(c, :chips, [])

        %{
          title: c.label,
          facts:
            [{"kind", "group"}, {"holds", c.hint |> String.split("·") |> hd() |> String.trim()}] ++
              if(chips == [], do: [], else: [{"members", Enum.join(chips, " · ")}]),
          note: note
        }

      %{facts: [_ | _] = facts} = c ->
        %{title: c.label, facts: facts, note: note}

      c ->
        fields = String.split(c.hint, ~r/\s{2,}/, trim: true)

        %{
          title: c.label,
          facts:
            case fields do
              [] -> []
              [one] -> [{"about", one}]
              many -> Enum.with_index(many, fn f, i -> {if(i == 0, do: "about", else: ""), f} end)
            end,
          note: note
        }
    end
  end

  defp tree(%{node: %{type: :split}} = assigns) do
    assigns = assign(assigns, ratio: Map.get(assigns.node, :ratio, 0.5))

    ~M"""
    <c-split class={"split #{@node.dir}"}>
      <c-group class="split-child" style={"flex: #{@ratio} 1 0%"}>
        <.tree node={Enum.at(@node.children, 0)} active={@active} completion={@completion} />
      </c-group>
      <c-group class="split-child" style={"flex: #{1.0 - @ratio} 1 0%"}>
        <.tree node={Enum.at(@node.children, 1)} active={@active} completion={@completion} />
      </c-group>
    </c-split>
    """
  end

  # A window is a stateful component so that a window nobody touched
  # costs nothing: the component's assign skips a value equal to the one
  # it holds, and a component with no changed assign renders nothing and
  # ships a skip placeholder. Without this, one keystroke in one window
  # re-sent every line of every other window, because the parent handed
  # each window a new node map on every render. The component id is the
  # id of the window's own div.
  defp tree(%{node: %{type: :leaf}} = assigns) do
    ~M"""
    <.live_component
      module={Compos.Ui.Window}
      id={"win-#{@node.id}"}
      node={@node}
      active={@active}
      completion={@completion}
    />
    """
  end

  @doc """
  One window: its header, dashboard, body, and modeline.

  `Compos.Ui.Window` renders this. It stays here because the helpers it
  calls (`blk`, `seg`, the modeline pieces) live here.
  """
  def window(assigns) do
    assigns =
      assign(assigns,
        lines: assigns.node.lines,
        line: assigns.node.line,
        col: assigns.node.col,
        # the file the window shows, and whether it refuses typing. The
        # client renders neither yet; /raw previews and the modeline will.
        path: assigns.node.path,
        read_only: assigns.node.read_only,
        dismissible?: Map.get(assigns.node, :dismissible, false),
        peek?: String.contains?(assigns.node.window_class || "", "listing-peek"),
        # the state the mode line draws, normalised: (KEY VALUE TONE RANK)
        facts: ml_facts(assigns.node),
        active?: assigns.node.id == assigns.active
      )

    ~M"""
    <c-window
      id={"win-#{@node.id}"}
      class={"window #{if Map.get(@node, :highlighted, false), do: "preview-highlight"} #{if @active?, do: "active", else: "inactive"} #{if @dismissible?, do: "dismissible"} #{if @node.selected, do: "buffer-selected"} #{if !@node.line_numbers, do: "no-nums"} #{@node.window_class}"}
      style={window_style(@node)}
      active={to_string(@active?)}
      buffer={@node.buffer}
      data-win-id={@node.id}
      data-buffer={@node.buffer}
      data-path={@path}
      data-read-only={to_string(@read_only)}
      data-editing={to_string(Map.get(@node, :editing, false))}
      phx-hook={if @peek?, do: "PeekCard"}
      role={if @peek?, do: "note"}
      aria-label={if @peek?, do: "Preview"}
    >
      <%= if @peek? do %>
        <c-group class="peek-card-header">
          <c-text class="peek-card-label">Preview</c-text>
          <c-text class="peek-card-title">{@node.header_line || @node.buffer}</c-text>
          <button type="button" tabindex="-1" class="peek-card-dismiss" aria-label="Dismiss preview (q)"><kbd>q</kbd></button>
        </c-group>
        <c-group class="peek-card-body">
          <c-group inert>
            <%= cond do %>
              <% @node.render_mode in ["html", "markdown"] and Map.has_key?(@node, :preview) -> %>
                <iframe class="peek-document" srcdoc={@node.preview}
                  sandbox="allow-same-origin" tabindex="-1" title={@node.header_line || @node.buffer}></iframe>
              <% @node.render_mode == "blocks" and Map.has_key?(@node, :blk) -> %>
                <.dynamic_tag tag_name={@node.blk_root.tag} {@node.blk_root.attrs}
                  class="blocks-view" style={@node.style}>
                  <.blk :for={b <- @node.blk} b={b} line={@node.blk_line} win={@node.id} />
                </.dynamic_tag>
              <% @node.render_mode == "agent" and Map.has_key?(@node, :ag_blocks) -> %>
                <Compos.Ui.AgentTranscript.composml blocks={@node.ag_blocks}
                  win={@node.id} buf={@node.buffer} verbosity={@node.agent.verbosity}
                  stick={false} scroll_top={0} scroll_anchor={nil} scroll_offset={0} follow_seq={0} peek={true} />
              <% Map.get(@node, :semantic_records) not in [nil, false, []] -> %>
                <.peek_text node={@node} />
              <% true -> %>
                <pre class="peek-plain">{@node.text}</pre>
            <% end %>
          </c-group>
        </c-group>
      <% else %>
      <%!-- Dismissal is one key and it costs no row. The q rides the top
             right corner of the window, on the empty end of whatever headline
             the buffer draws for itself. Nobody needs the word Back. --%>
      <button :if={@dismissible?} type="button" class="dismiss-action" phx-click="ui_cmd"
        phx-value-win={@node.id} phx-value-cmd="dismiss-buffer"
        aria-label="Dismiss child or go back (q)"><kbd>q</kbd></button>
      <c-headerline :if={@node.header_line} class="buffer-header">{@node.header_line}</c-headerline>
      <c-group :if={@node.dash || @node.dashboard_line_blocks} class="dash-top">
        <%!-- The window's header line: identity. Scheme builds every block
               (dashboard-line-blocks): the group pin, the title, the open
               change, the cua/focus tag and the one switcher. data-pin marks
               a window whose buffer is in a group other than the frame's;
               only then does the pin show. --%>
        <c-headerline
          :if={@node.dashboard_line_blocks}
          class="dash-persistent"
          title="open dashboard"
          data-pin={Map.get(@node, :pin)}
          phx-click="ui_cmd"
          phx-value-win={@node.id}
          phx-value-cmd="modeline-expand"
        >
          <.blk :for={b <- @node.dashboard_line_blocks || []} b={block_view(b)} line={-1} win={@node.id} />
        </c-headerline>
        <c-group :if={@node.dash} class="dash-live">
          <c-text>L{@line}:C{@col}</c-text>
          <c-text>point {@node.point}</c-text>
          <c-text>{ml_bytes(@node.text)}</c-text>
          <c-text>{pct(@node)}</c-text>
          <c-text :if={@node.modified} class="dash-live-mod">modified</c-text>
        </c-group>
        <%!-- The modes card is the dashboard's own, built in Scheme beside
               the group, tools and llm cards. A second one drawn here said
               the same thing twice. --%>
        <%= case @node.dash do %>
          <% [head | cards] -> %>
            <.blk b={block_view(head)} line={0} win={@node.id} />
            <c-group class="dash-grid">
              <.blk :for={b <- Enum.map(cards, &block_view/1)} b={b} line={0} win={@node.id} />
            </c-group>
          <% _ -> %>
        <% end %>
      </c-group>
      <%= if @node.render_mode == "terminal" do %>
        <c-group
          class="terminal-view"
          id={"terminal-#{@node.id}"}
          phx-hook="Terminal"
          phx-update="ignore"
          data-buffer={@node.buffer}
          data-win={@node.id}
        ></c-group>
      <% else %>
      <%= if @node.render_mode == "blocks" and Map.has_key?(@node, :blk) do %>
        <.dynamic_tag tag_name={@node.blk_root.tag} class="blocks-view" style={@node.style} id={"blocks-#{@node.id}"} phx-hook="BlockScroll" {@node.blk_root.attrs}>
          <c-buffer class="blocks-scroll">
            <.blk :for={b <- @node.blk} b={b} line={@node.blk_line} win={@node.id} />
          </c-buffer>
        </.dynamic_tag>
      <% else %>
      <%= if @node.render_mode == "agent" and Map.has_key?(@node, :ag_blocks) do %>
        <c-buffer
          class="agent-view"
          id={"agent-#{@node.id}"}
          style={@node.style}
        >
          <%!-- the transcript is its own component so a keystroke in the
               input row diffs to a skip placeholder: the client must not
               walk one DOM node per block of the whole conversation per
               key. blocks comes from the decorate cache, so the list is
               reference-equal until the block model changes. --%>
          <.live_component
            module={Compos.Ui.AgentTranscript}
            id={"agtx-#{@node.id}"}
            blocks={@node.ag_blocks}
            win={@node.id}
            buf={@node.buffer}
            verbosity={@node.agent.verbosity}
            stick={@node.agent.stick}
            scroll_top={@node.agent.scroll_top}
            scroll_anchor={@node.agent.scroll_anchor}
            scroll_offset={@node.agent.scroll_offset}
        follow_seq={@node.agent.follow_seq}
          />
          <%!-- messages queued mid-turn: muted rows from 'chat-queued,
               not transcript text. Outside the component, so a streamed
               event never moves them and their churn never diffs the
               block list — excise + re-insert per event was the flicker.
               C-c C-d takes the newest one back into the input. --%>
          <c-user :for={q <- @node.ag_queued} state="queued" class="ag-user ag-queued ag-queued-row">
            <c-label class="ag-label">YOU</c-label>
            <c-group class="ag-user-text">{q}</c-group>
          </c-user>
          <%!-- the turn pulse: the activity word agent.scm sets on every
               event, alive until turn-end clears it. The transcript alone
               cannot say working vs done once paragraphs stream. Outside
               the component and the scroll area, so it never moves and
               its churn never diffs the block list. "disconnected" is a
               dead chat, not motion — the [agent exited] line says it. --%>
          <c-activity
            :if={@node.ag_activity && @node.ag_activity != "disconnected"}
            id={"ag-activity-#{@node.id}"}
            class="ag-wait ag-activity"
          ><c-text class="ag-activity-text">⋯ {@node.ag_activity}</c-text></c-activity>
          <c-prompt class="ag-inputrow">
            <c-label class="ag-label">YOU</c-label>
            <c-input class="ag-input">{@node.ag_input.pre}<c-cursor
                :if={@node.ag_input.cur != "" && Map.get(@node, :cursor_visible, true)}
                class="cursor"
              >{@node.ag_input.cur}</c-cursor>{@node.ag_input.post}</c-input>
            <%!-- completion-at-point, at the prompt. The transcript is not
                 drawn from .line rows, so the popup the line renderer carries
                 never reaches a chat: this is the same card, anchored to the
                 input row and opening upward, because the row sits at the
                 window's foot and there is no room below it. --%>
            <%= if @active? && @completion do %><c-text
              class="cap-pop cap-pop-up"
              contenteditable="false"
            ><c-text class="cap-title">completion-at-point · {@completion.total}</c-text><c-text
              :for={c <- @completion.candidates}
              class={"cap-row #{if c.selected, do: "selected"}"}
            ><c-text class="cap-label">{c.label}</c-text><c-text class="cap-kind">{c.hint}</c-text></c-text><c-text
              :for={c <- @completion.candidates}
              :if={c.selected}
              class="cap-doc"
              popover="manual"
              role="note"
              aria-label="Completion documentation"
            ><c-text class="cap-doc-name">{c.label}</c-text><c-text class="cap-doc-body">{completion_doc(c)}</c-text></c-text></c-text><% end %>
            <c-key-hints
              :if={@node.ag_input.pre == "" and @node.ag_input.post == ""}
              class="ag-hint"
            >RET sends · C-RET interrupts</c-key-hints>
          </c-prompt>
        </c-buffer>
      <% else %>
      <%= if @node.render_mode == "file" and Map.has_key?(@node, :file_url) do %>
        <c-preview kind="file" source={@node.file_url} buffer={@node.buffer} style="display: contents">
        <iframe
          class="file-preview"
          src={@node.file_url}
          sandbox=""
          title={@node.buffer}
        ></iframe>
        </c-preview>
      <% else %>
      <%= if @node.render_mode == "app" and Map.has_key?(@node, :app_url) do %>
        <%!-- An app runs its own scripts, so it must not share the editor's
             origin: it is served from 127.0.0.1:4005, and the parent is
             localhost:4004. allow-same-origin here grants the app its OWN
             origin, which buys it storage and relative URLs; the browser
             still refuses it every reach into this page. src, not srcdoc,
             for the same reason — a srcdoc document inherits us. --%>
        <c-preview kind="app" source={@node.app_url} buffer={@node.buffer} style="display: contents">
        <iframe
          class="app-preview"
          id={"app-#{@node.id}-#{:erlang.phash2(@node.app_url)}"}
          phx-hook="AppFrame"
          data-win={@node.id}
          data-ctop={@node.ctop}
          sandbox="allow-scripts allow-same-origin allow-forms allow-modals allow-popups"
          src={@node.app_url}
          title={@node.buffer}
        >
        </iframe>
        </c-preview>
      <% else %>
      <%= if @node.render_mode in ["html", "markdown"] do %>
        <%!-- allow-same-origin, and nothing else. The parent must reach
             the frame's document to scroll it from a key; without it the
             page only answers the mouse. No allow-scripts, so the
             previewed document still runs nothing. --%>
        <c-preview kind="document" format={@node.render_mode} source={@node.buffer} buffer={@node.buffer} style="display: contents">
        <iframe
          class="html-preview"
          id={"prev-#{@node.id}"}
          phx-hook="PreviewScroll"
          style={@node.style}
          data-win={@node.id}
          data-ctop={@node.ctop}
          data-pt={@node.point}
          data-rm={@node.render_mode}
          data-visual-lines={to_string(@node.visual_line_mode)}
          data-v={@node.version}
          data-doc={Base.encode64(@node.preview)}
          sandbox="allow-same-origin"
          title={@node.buffer}
        ></iframe>
        </c-preview>
      <% else %>
      <.dynamic_tag tag_name={block_root(Map.get(@node, :text_root)).tag}
        {block_root(Map.get(@node, :text_root)).attrs}
        class={"buf #{if @node.client_scroll?, do: "client-scroll"}"}
        style={@node.style}
        data-ctop={@node.ctop}
        data-manual={to_string(@node.manual)}
        data-scroll={scroll_request(@node)}
        data-visual-lines={to_string(@node.visual_line_mode)}
        data-hl-line={to_string(Map.get(@node, :hl_line, true))}
        data-ws={to_string(whitespace?(@node))}
        data-v={@node.version}
        data-pt={@node.point}
        data-mark={@node.mark}
        contenteditable={if @node.read_only, do: nil, else: "true"}
        spellcheck="true"
        autocorrect="off"
        autocapitalize="off"
      >
        <%= for group <- semantic_line_groups(@lines, Map.get(@node, :semantic_records)) do %>
        <%= if group.direct do %>
          <.dynamic_tag :for={ln <- group.lines} tag_name={group.tag} {group.attrs}
            id={"ln-#{@node.id}-#{ln.num}"}
            class={"line line-content semantic-direct #{ln.row} #{if ln.current, do: "hl-line"} #{if ln.selected, do: "selected-line"}"}
            data-s={ln.start} data-line={ln.num} selected={to_string(ln.current)}><.semantic_line id_prefix={"sg-#{@node.id}-#{ln.num}"} segs={ln.segs} start={ln.start} fields={group.fields} base={@node.buffer} win={@node.id} direct={true} /></.dynamic_tag>
        <% else %>
        <.dynamic_tag tag_name={group.tag} class="semantic-record" style="display: contents" {group.attrs}>
        <c-line
          :for={ln <- group.lines}
          id={"ln-#{@node.id}-#{ln.num}"}
          class={"line #{ln.row} #{if ln.current, do: "hl-line"} #{if ln.selected, do: "selected-line"}"}
          data-s={ln.start}
        >
          <c-text class="linenum" contenteditable="false">{ln.num}</c-text>
          <c-text class="line-content"><.semantic_line id_prefix={"sg-#{@node.id}-#{ln.num}"} segs={ln.segs} start={ln.start} fields={group.fields} base={@node.buffer} win={@node.id} /><br
              :if={ln.segs == []}
              class="empty-row"
            /><%= if @active? && @completion && ln.at_point do %><c-text
              class="cap-pop"
              contenteditable="false"
              style={"left: #{pop_col(@node.text, ln.start, @completion.start)}ch"}
            ><c-text class="cap-title">completion-at-point · {@completion.total}</c-text><c-text
              :for={c <- @completion.candidates}
              class={"cap-row #{if c.selected, do: "selected"}"}
            ><c-text class="cap-label">{c.label}</c-text><c-text class="cap-kind">{c.hint}</c-text></c-text><c-text
              :for={c <- @completion.candidates}
              :if={c.selected}
              class="cap-doc"
              popover="manual"
              role="note"
              aria-label="Completion documentation"
            ><c-text class="cap-doc-name">{c.label}</c-text><c-text class="cap-doc-body">{completion_doc(c)}</c-text></c-text></c-text><% end %></c-text>
        </c-line>
        </.dynamic_tag>
        <% end %>
        <% end %>
      </.dynamic_tag>
      <% end %>
      <% end %>
      <% end %>
      <% end %>
      <% end %>
      <% end %>
      <c-group :if={@node.footer_line || Map.get(@node, :footer_line_blocks)} class="buffer-footer">
        <.blk :for={b <- Map.get(@node, :footer_line_blocks) || []} b={block_view(b)} line={-1} win={@node.id} />
        {@node.footer_line}
      </c-group>
      <c-modeline class="modeline">
        <%!-- the header line names the buffer; the mode line does not say
               it again. The dot is the state and opens the dashboard. --%>
        <c-text
          class={"ml-dot #{if @node.modified, do: "modified"}"}
          title={@node.buffer}
          phx-click="ui_cmd"
          phx-value-win={@node.id}
          phx-value-cmd="modeline-expand"
        ></c-text>
        <c-field name="project" :if={@node.modeline_project && @node.modeline_project != ""} class="ml-project">{@node.modeline_project}</c-field>
        <c-status state="selected" :if={@node.selected} class="ml-mode ml-selected">● selected</c-status>
        <c-mode :if={@node.render_mode in ["html", "markdown"]} class="ml-mode">preview</c-mode>
        <c-field name="info"
          :if={@node.modeline_info}
          class="ml-mode"
          phx-click="ui_cmd"
          phx-value-win={@node.id}
          phx-value-buf={@node.buffer}
        >{@node.modeline_info}</c-field>
        <%!-- the facts: mode, llm, lane (or the preset alone), each a key
               and a value, ranked so a narrow window sheds them in order --%>
        <c-group :if={@facts != []} class="ml-facts">
          <c-field :for={{k, v, tone, rank} <- @facts} name={k} class="ml-fact" tone={tone} rank={rank}><c-label class="ml-fact-k">{k}</c-label><c-value class={"ml-fact-v #{tone}"}>{v}</c-value></c-field>
        </c-group>
        <c-text class="mb-spacer"></c-text>
        <%!-- the position sheds by rank too: the size first, then the
               percentage, then the whole of it. The name is identity and
               is the last thing on the line to give way. --%>
        <c-position class="ml-pos" line={@line} column={@col}>
          <%= if @node.render_mode == "terminal" do %>
            PTY · <c-text class="ml-pos-size">transcript {ml_bytes(@node.text)}</c-text>
          <% else %>
            <c-text class="ml-pos-size">{ml_bytes(@node.text)} · </c-text>L{@line}:C{@col}<c-text class="ml-pos-pct"> · {pct(@node)}</c-text>
          <% end %>
        </c-position>
      </c-modeline>
      <% end %>
    </c-window>
    """
  end

  # --- per-line display list: numbers, hl-line, font-lock + overlays ----------

  # The focused editable surface draws no cursor and no region of its own.
  # The browser owns the caret and selection there. An inactive editable
  # surface draws the server marker, so its window still shows point.
  defp render_pass(static, text, point, mark, native_caret?, show_cursor?) do
    {rs, re} =
      case mark do
        nil -> {point, point}
        m -> {min(m, point), max(m, point)}
      end

    len = byte_size(text)

    cursor_end =
      case String.next_grapheme(binary_part(text, point, len - point)) do
        nil -> point
        {g, _} -> point + byte_size(g)
      end

    Enum.map(static, fn line ->
      le = line.start + byte_size(line.part)
      # The native-caret surface marks its current row in the client.
      # Nothing in these lines depends on point, so caret motion sends no row.
      # at_point says the same thing WITHOUT that gate: the completion card
      # anchors to the line point is on, and that line is exactly the one
      # the client owns the caret for, so keying the card off `current`
      # meant it could never draw in an editable buffer.
      at_point = point >= line.start and point <= le
      current = not native_caret? and at_point
      touched? = current or (rs != re and rs < le + 1 and re > line.start)

      segs =
        if touched? and not native_caret? do
          # Images are atomic display objects. Point may sit inside the URL
          # backing one, but the cursor must not split its scheme before the
          # image component sees it.
          image_at_point =
            Enum.find(line.ov, fn
              {s, e, cls} when is_binary(cls) ->
                cls =~ "img-embed" and point >= s and point < e

              _ ->
                false
            end)

          overlays =
            [
              if(rs != re, do: {rs, re, "region"}),
              if(show_cursor? and point < cursor_end and is_nil(image_at_point),
                do: {point, cursor_end, "cursor"}
              )
            ]
            |> Enum.reject(&is_nil/1)

          # through line_segs, not seg_build: the cursor's own line takes the
          # same long-line guard as every other one, and on a one-line buffer
          # this is the only line there is
          segs =
            line_segs(
              line.part,
              line.start,
              line.ts,
              line.ov ++ overlays,
              Map.get(line, :chrome, [])
            )

          segs =
            case image_at_point do
              {s, e, _} ->
                target = binary_part(text, s, e - s)

                {before, from_image} =
                  Enum.split_while(segs, fn
                    {^target, cls} when is_binary(cls) -> not (cls =~ "img-embed")
                    _ -> true
                  end)

                case from_image do
                  [image | after_image] when point == s ->
                    before ++ [{@cursor_placeholder, "cursor"}, image | after_image]

                  [image | after_image] ->
                    before ++ [image, {@cursor_placeholder, "cursor"} | after_image]

                  [] ->
                    segs
                end

              nil ->
                segs
            end

          # cursor sitting on this line's newline (or at EOF on the last line)
          if show_cursor? and point >= line.start and point == le,
            do: segs ++ [{@cursor_placeholder, "cursor"}],
            else: segs
        else
          line.segs
        end

      %{
        num: line.num,
        current: current,
        at_point: at_point,
        selected: line.selected,
        start: line.start,
        row: Map.get(line, :row, ""),
        segs: segs
      }
    end)
  end

  # cut the line at every range boundary; each segment takes the last-wins
  # ts class plus any active overlay classes
  # a seg whose overlay face says img-embed IS an image: the buffer text
  # stays the URL (the buffer is truth), the client draws the picture
  # An island draws in the text's place and is one character to the caret
  # (contenteditable=false): an image, an X card, or a YouTube card.
  # data-len says how many source bytes it stands for, so the
  # client's byte mapping walks over it.
  # the id keys the node for the DOM patcher: without one, LiveView
  # stamps a fresh magic id on every render of this comprehension and
  # morphdom tears the span down and builds it again instead of writing
  # the new text into it
  attr(:id, :string, required: true)
  attr(:txt, :string, required: true)
  attr(:cls, :string, required: true)
  attr(:base, :string, default: nil)
  attr(:win, :any, default: nil)

  defp seg(%{cls: cls, txt: txt} = assigns)
       when is_binary(cls) and is_binary(txt) do
    src = if cls =~ "img-embed", do: image_src(txt, assigns.base)
    assigns = assign(assigns, href: link_href(cls))

    cond do
      # chrome: text the buffer does not hold, standing at one byte and
      # holding zero bytes; the byte walker skips it by its data-len.
      # A click id routes through the block-click registry like a block
      # tree's click.
      String.starts_with?(cls, "chrome-seg") ->
        {shown, click} = chrome_click_off(cls)
        assigns = assign(assigns, cls: shown, click: click)

        ~M"""
        <c-text
          id={@id}
          class={@cls}
          contenteditable="false"
          data-len="0"
          phx-click={@click && "block_click"}
          phx-value-win={@click && @win}
          phx-value-id={@click}
        >{@txt}</c-text>
        """

      is_binary(src) ->
        avatar? = String.ends_with?(txt, "#compos-avatar")

        assigns =
          assign(assigns,
            src: src,
            len: byte_size(txt),
            image_class: if(avatar?, do: "img-embed img-avatar", else: "img-embed")
          )

        ~M|<img id={@id} src={@src} class={@image_class} loading="lazy" contenteditable="false" data-len={@len} />|

      cls =~ "x-embed" ->
        assigns = assign(assigns, len: byte_size(txt), card: Compos.Ui.Oembed.card(txt))

        ~M"""
        <c-text id={@id} class="x-card" contenteditable="false" data-len={@len}><%= case @card do %><% {:ok, html} -> %>{Phoenix.HTML.raw(html)}<% _ -> %><c-text class="x-pending">{@txt}</c-text><% end %></c-text>
        """

      cls =~ "youtube-embed" and Classic.youtube_id(txt) ->
        id = Classic.youtube_id(txt)

        assigns =
          assign(assigns,
            len: byte_size(txt),
            thumbnail: Classic.youtube_thumbnail(id)
          )

        ~M"""
        <a id={@id} class="youtube-card youtube-island" href={@txt} target="_blank" rel="noopener noreferrer" contenteditable="false" data-len={@len} aria-label="Watch this video on YouTube"><img src={@thumbnail} alt="YouTube video thumbnail" loading="lazy" /><c-text class="youtube-play" aria-hidden="true">▶</c-text></a>
        """

      true ->
        ~M|<c-text id={@id} class={@cls} data-href={@href}>{@txt}</c-text>|
    end
  end

  # a URL draws as it is; a relative path resolves beside the buffer's
  # file and is served signed (LocalImage); a path with no file has no picture
  defp image_src(txt, base) do
    cond do
      # a base64 picture is its own source: the bytes stand in the text,
      # the browser decodes them, and nothing is fetched
      String.starts_with?(txt, "data:image/") ->
        String.trim_trailing(txt, "#compos-avatar")

      String.starts_with?(txt, "http") ->
        String.trim_trailing(txt, "#compos-avatar")

      is_binary(base) and String.starts_with?(base, "/") ->
        LocalImage.url(Path.expand(txt, Path.dirname(base)))

      String.starts_with?(txt, "/") ->
        LocalImage.url(txt)

      true ->
        nil
    end
  end

  # take the click id back off a chrome seg's class; the shown class keeps
  # only the styling tokens
  defp chrome_click_off(cls) do
    {clicks, rest} =
      cls |> String.split(" ") |> Enum.split_with(&String.starts_with?(&1, "chrome-click:"))

    click =
      case clicks do
        ["chrome-click:" <> id | _] -> URI.decode(id)
        [] -> nil
      end

    {Enum.join(rest, " "), click}
  end

  # A drawn Markdown link carries its target in its class, because a class
  # is the only channel a span has. The reader clicks the text; the client
  # reads the target back off the element.
  defp link_href(cls) do
    cls
    |> String.split(" ")
    |> Enum.find_value(fn
      "link-to:" <> encoded -> URI.decode(encoded)
      _ -> nil
    end)
  end

  defp seg_build(part, ls, ts_ranges, overlays) do
    plen = byte_size(part)
    le = ls + plen
    rel = fn abs -> abs |> max(ls) |> min(le) |> Kernel.-(ls) end

    cuts =
      Enum.flat_map(ts_ranges, fn {s, e, _, _} -> [rel.(s), rel.(e)] end) ++
        Enum.flat_map(overlays, fn {s, e, _} -> [rel.(s), rel.(e)] end)

    # snap every cut down to a character boundary. A tree-sitter range or
    # an overlay can end inside a multi-byte character; the binary_part
    # below then builds a segment that is not valid UTF-8, and Jason kills
    # the LiveView socket when it encodes the reply. The window goes blank
    # and the client cannot reconnect. Snapping keeps the segments tiling
    # the line exactly, because floor_utf8 holds 0 and plen fixed.
    ([0, plen] ++ cuts)
    |> Enum.map(&Text.floor_utf8(part, &1))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] ->
      if b > a do
        a2 = ls + a
        b2 = ls + b

        ts_cls =
          ts_ranges
          |> Enum.filter(fn {s, e, _, _} -> s <= a2 and e >= b2 end)
          |> Enum.max_by(fn {_, _, _, i} -> i end, fn -> nil end)
          |> case do
            {_, _, cls, _} -> cls
            nil -> nil
          end

        ov_cls =
          overlays
          |> Enum.filter(fn {s, e, _} -> s <= a2 and e >= b2 end)
          |> Enum.map(fn {_, _, cls} -> cls end)

        cls = Enum.join(Enum.reject([ts_cls | ov_cls], &is_nil/1), " ")
        [{binary_part(part, a, b - a), cls}]
      else
        []
      end
    end)
  end

  # both previews follow the live theme; `(buffer-set-local! buf
  # 'preview-authored #t)` renders html exactly as authored instead
  # --- agent transcript blocks ------------------------------------------------

  # block offsets can go stale (they're laid down at insert time, and text
  # before them may be edited); a mid-codepoint slice is invalid UTF-8 and
  # kills the whole render (Earmark, HEEx).
  defp safe_slice(text, s, e), do: Text.slice(text, s, e)

  defp ag_block([s, e, "user" | meta], text, _open) do
    text_of =
      case meta do
        [msg | _] when is_binary(msg) -> msg
        _ -> text |> safe_slice(s, e) |> String.trim() |> String.replace_prefix(">>> you: ", "")
      end

    %{kind: :user, text: text_of}
  end

  # a message queued mid-turn: the user line, muted until the model reads it
  defp ag_block([s, e, "queued" | meta], text, _open) do
    text_of =
      case meta do
        [msg | _] when is_binary(msg) -> msg
        _ -> text |> safe_slice(s, e) |> String.trim() |> String.replace_prefix(">>> you: ", "")
      end

    %{kind: :queued, text: text_of}
  end

  defp ag_block([s, e, "prose" | _], text, _open) do
    %{kind: :prose, html: text |> safe_slice(s, e) |> prose_html() |> wrap_tables()}
  end

  defp ag_block([s, e, "thought" | _], text, _open),
    do: %{kind: :thought, text: String.trim(safe_slice(text, s, e))}

  defp ag_block([_s, e, "tool", id, title, kind, status, body_start | rest], text, open_cards) do
    raw_body = String.trim_trailing(safe_slice(text, body_start, e))
    body = tool_display_body(raw_body)

    # "name: arg" from agent-tool-title — the arg is the interesting part,
    # so the card styles it apart from the tool name
    {name, arg} =
      case String.split(title, ": ", parts: 2) do
        [n, a] -> {n, a}
        _ -> {title, ""}
      end

    %{
      kind: :tool,
      id: id,
      title: title,
      name: name,
      arg: arg,
      verb: kind,
      status: status,
      open: id in open_cards,
      body: body,
      preview: tool_preview(body),
      duration: tool_duration_label(List.first(rest)),
      # what the call added to the context: its arguments and its result
      tokens: token_estimate_label(byte_size(title) + byte_size(raw_body))
    }
  end

  defp ag_block([s, e, "plan" | _], text, _open),
    do: %{kind: :plan, text: String.trim(safe_slice(text, s, e))}

  defp ag_block([_s, _e, "permission", title | _], _text, _open),
    do: %{kind: :permission, title: title}

  defp ag_block([_s, _e, "question", id, slug, question, answers | _], _text, _open),
    do: %{kind: :question, id: id, slug: slug, question: question, answers: answers || []}

  # the waiting block anchors the "⋯ thinking" text for restore sweeps and
  # the plain view; the rich view shows the activity row instead — both at
  # once would pulse twice for one wait
  defp ag_block([_s, _e, "waiting" | _], _text, _open), do: nil

  defp ag_block([s, e, "status" | _], text, _open),
    do: %{kind: :status, text: String.trim(safe_slice(text, s, e))}

  # a pasted attachment: the bytes are a file, the block names it, and the
  # transcript shows the picture rather than the path
  defp ag_block([_s, _e, "image", path | _], _text, _open),
    do: %{kind: :image, src: Compos.Ui.LocalImage.url(path), name: Path.basename(path)}

  # the chat prompt is a REPL: the expression and the value it printed are
  # code, so they keep their own spacing instead of reflowing as prose
  defp ag_block([s, e, "eval" | _], text, _open),
    do: %{kind: :eval, text: String.trim(safe_slice(text, s, e))}

  defp ag_block([s, e, "meta" | _], text, _open),
    do: %{kind: :meta, text: String.trim(safe_slice(text, s, e))}

  defp ag_block(_, _, _), do: nil

  # The transcript is markdown; the page renderer draws it (core).
  defp prose_html(md), do: Compos.Core.Markdown.Html.prose(md)

  # "340ms", "1.4s", "2m 05s" — nil when the block predates the field
  defp tool_duration_label(ms) when is_integer(ms) and ms >= 0 do
    cond do
      ms < 1000 -> "#{ms}ms"
      ms < 60_000 -> "#{Float.round(ms / 1000, 1)}s"
      true -> "#{div(ms, 60_000)}m #{String.pad_leading("#{rem(div(ms, 1000), 60)}", 2, "0")}s"
    end
  end

  defp tool_duration_label(_), do: nil

  # bytes/4 is the standard rough token estimate; no tokenizer ships here
  defp token_estimate_label(bytes) when bytes < 4, do: nil

  defp token_estimate_label(bytes) do
    tokens = div(bytes, 4)

    if tokens < 1000 do
      "~#{tokens} tok"
    else
      "~#{Float.round(tokens / 1000, 1)}k tok"
    end
  end

  # A folded call still says what it returned. New calls separate input and
  # output with a blank line. Older calls contain only their result.
  defp tool_preview(body) do
    candidate =
      case String.split(String.trim(body), ~r/\n\s*\n/, parts: 2) do
        [_input, output] when output != "" -> output
        [detail | _] -> detail
        _ -> ""
      end

    candidate
    |> tool_result_text()
    |> String.split("\n", parts: 2)
    |> List.first()
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 140)
  end

  # Keep the canonical transcript unchanged. The rich view unwraps only the
  # final MCP result envelope and leaves the tool input before it intact.
  defp tool_display_body(body) do
    parts = String.split(body, "\n\n")
    result = List.last(parts) || ""
    readable = tool_result_text(result)

    if readable == result do
      body
    else
      parts
      |> List.replace_at(-1, readable)
      |> Enum.join("\n\n")
    end
  end

  defp tool_result_text(text) do
    case Jason.decode(String.trim(text)) do
      {:ok, %{"content" => content} = result} when is_list(content) ->
        case Enum.find_value(content, fn
               %{"text" => value} when is_binary(value) and value != "" -> value
               _ -> nil
             end) do
          nil -> Jason.encode!(result, pretty: true)
          value -> pretty_json(value)
        end

      {:ok, value} ->
        Jason.encode!(value, pretty: true)

      _ ->
        text
    end
  end

  defp pretty_json(text) do
    case Jason.decode(String.trim(text)) do
      {:ok, value} -> Jason.encode!(value, pretty: true)
      _ -> text
    end
  end

  # The one renderer for block trees. Structure only: tags, classes, segs,
  # click ids and the point mark all come from the mode. The mark: a block
  # with a mark class and a line range gets that class while point's line is
  # inside the range — and, when it also has an anchor, a data-current
  # attribute the scroll hook follows.
  defp blk(%{b: %{tag: "pre"}} = assigns) do
    ~M|<pre class={blk_class(@b, @line)}>{@b.text}</pre>|
  end

  defp blk(%{b: %{tag: "span"}} = assigns) do
    ~M|<c-text class={blk_class(@b, @line)}><.dynamic_tag :for={{c, t, tag} <- @b.semantic_segs} tag_name={tag} class={c} face={block_faces(c)}>{t}</.dynamic_tag><%= if @b.text do %>{@b.text}<% end %></c-text>|
  end

  defp blk(%{b: %{tag: "div"}} = assigns) do
    ~M"""
    <c-group
      class={blk_class(@b, @line)}
      data-anchor={@b.anchor}
      data-current={if @b.anchor && blk_current?(@b, @line), do: "1"}
      phx-click={@b.click && "block_click"}
      phx-value-win={@b.click && @win}
      phx-value-id={@b.click}
      {@b.attrs}
    ><.dynamic_tag :for={{c, t, tag} <- @b.semantic_segs} tag_name={tag} class={c} face={block_faces(c)}>{t}</.dynamic_tag><%= if @b.text do %>{@b.text}<% end %><.blk :for={c <- @b.children} b={c} line={@line} win={@win} /></c-group>
    """
  end

  # a product photo or an embedded picture, drawn from its src attr
  defp blk(%{b: %{tag: "img"}} = assigns) do
    ~M|<img class={blk_class(@b, @line)} {@b.attrs} loading="lazy" />|
  end

  # any other tag: an SVG chart, a table, a label. The attributes are the
  # mode's, filtered by the allowlist below; a click still routes by id.
  defp blk(assigns) do
    ~M"""
    <.dynamic_tag
      tag_name={@b.tag}
      class={blk_class(@b, @line)}
      id={@b.anchor && "block-#{@win}-#{@b.anchor}"}
      data-anchor={@b.anchor}
      data-current={if @b.anchor && blk_current?(@b, @line), do: "1"}
      {if @b.anchor, do: [{"selected", to_string(blk_current?(@b, @line))}], else: []}
      phx-click={@b.click && "block_click"}
      phx-value-win={@b.click && @win}
      phx-value-id={@b.click}
      {@b.attrs}
    ><c-text :if={{"marked", "true"} in @b.attrs} class="list-mark" aria-label="Marked">✱</c-text><.dynamic_tag :for={{c, t, tag} <- @b.semantic_segs} tag_name={tag} class={c} face={block_faces(c)}>{t}</.dynamic_tag><%= if @b.text do %>{@b.text}<% end %><.blk :for={c <- @b.children} b={c} line={@line} win={@win} /></.dynamic_tag>
    """
  end

  # the server's last scroll of a client-scrolled window: "GEN:LINES". The
  # client applies a request once, when the generation is new to it.
  defp scroll_request(%{scroll_gen: gen, scroll_lines: lines}) when is_integer(gen),
    do: "#{gen}:#{lines}"

  defp scroll_request(_node), do: nil

  defp blk_class(b, line),
    do: if(blk_current?(b, line), do: "#{b.class} #{b.mark}", else: b.class)

  defp block_faces(classes) do
    classes |> String.split() |> Enum.filter(&String.starts_with?(&1, "f-"))
    |> Enum.map(&String.replace_prefix(&1, "f-", "")) |> Enum.join(" ")
  end

  defp blk_current?(%{lines: [a, b], mark: m}, line) when is_binary(m),
    do: line >= a and line <= b

  defp blk_current?(_, _), do: false

  # The tags and attributes a block may carry beyond the structural keys.
  # Presentation only: style, and the SVG geometry and paint attributes.
  # Nothing that loads a resource, runs a script, or submits a form. A tag
  # outside the list draws as a div, an attribute outside it is dropped.
  @block_tags Compos.Ui.ComposML.domain_elements() ++ Compos.Ui.ComposML.elements() ++ ~w(div span pre kbd p h1 h2 h3 h4 table thead tbody tr th td ul ol li
                 svg g path rect circle ellipse line polyline polygon text tspan title img)
  @block_attrs ~w(path bytes mtime permissions mark mode source profile field record-id query unread marked message-id content-type part-id name face state level role aria-level modified folded value max unit kind target glyph style d viewBox preserveAspectRatio fill stroke stroke-width
                  stroke-dasharray stroke-dashoffset stroke-linecap stroke-linejoin
                  stroke-opacity fill-opacity fill-rule opacity x y x1 y1 x2 y2 cx cy r rx ry
                  width height points transform vector-effect text-anchor font-size
                  dominant-baseline shape-rendering title colspan rowspan src alt)

  defp semantic_line(%{fields: []} = assigns) do
    ~M"""
    <.seg :for={{{txt, cls}, sx} <- Enum.with_index(@segs)} id={"#{@id_prefix}-#{sx}"} txt={txt} cls={cls} base={@base} win={@win} />
    """
  end

  defp semantic_line(assigns) do
    {segments, _} =
      Enum.map_reduce(assigns.segs, assigns.start, fn {txt, cls}, at ->
        {{at, at + byte_size(txt), txt, cls}, at + byte_size(txt)}
      end)

    stop =
      case List.last(segments) do
        nil -> assigns.start
        {_, b, _, _} -> b
      end

    fields = Enum.filter(assigns.fields, fn {a, b, _} -> a < stop and b > assigns.start end)
    # A field range is bytes, and it can end inside a multi-byte character:
    # a list row draws box characters, and the column the block declares
    # lands on the second byte of one. The binary_part below then cuts a
    # segment that is not valid UTF-8, and Jason kills the LiveView socket
    # when it encodes the reply. Snap every boundary down to a character
    # boundary first. The tiling holds, because floor_utf8 keeps
    # assigns.start and stop fixed.
    line = Enum.map_join(segments, &elem(&1, 2))
    snap = fn at -> assigns.start + Text.floor_utf8(line, at - assigns.start) end
    boundaries = ([assigns.start, stop] ++ Enum.flat_map(fields, fn {a, b, _} -> [max(a, assigns.start), min(b, stop)] end)) |> Enum.map(snap) |> Enum.uniq() |> Enum.sort()
    pieces = for [a, b] <- Enum.chunk_every(boundaries, 2, 1, :discard), a < b do
      field = Enum.find_value(fields, fn {x, y, field} -> if x <= a and b <= y, do: field end)
      segs = for {x, y, txt, cls} <- segments, x < b and y > a, do: {binary_part(txt, max(x, a) - x, min(y, b) - max(x, a)), cls}
      prefix = for {x, y, txt, _} <- segments, x < a, do: binary_part(txt, 0, min(y, a) - x)
      %{field: field, segs: segs, col: String.length(Enum.join(prefix)), width: max(1, String.length(Enum.map_join(segs, &elem(&1, 0))))}
    end
    assigns = assigns |> assign(:pieces, pieces) |> assign(:direct, Map.get(assigns, :direct, false))
    ~M"""
    <%= for {piece, px} <- Enum.with_index(@pieces) do %><%= if piece.field do %><%= if @direct do %><.direct_field id_prefix={"#{@id_prefix}-#{px}"} field={piece.field} segs={piece.segs} col={piece.col} width={piece.width} base={@base} win={@win} /><% else %><.dynamic_tag tag_name={piece.field.tag} {piece.field.attrs} class={piece.field.class}><.seg :for={{{txt, cls}, sx} <- Enum.with_index(piece.segs)} id={"#{@id_prefix}-#{px}-#{sx}"} txt={txt} cls={cls} base={@base} win={@win} /></.dynamic_tag><% end %><% else %><%= unless @direct do %><.seg :for={{{txt, cls}, sx} <- Enum.with_index(piece.segs)} id={"#{@id_prefix}-#{px}-#{sx}"} txt={txt} cls={cls} base={@base} win={@win} /><% end %><% end %><% end %>
    """
  end

  # Uniform field styling belongs on the domain element itself. Only mixed
  # cursor/face runs need inner spans.
  defp direct_field(assigns) do
    classes = assigns.segs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    assigns = assign(assigns, uniform: length(classes) == 1, face_class: List.first(classes) || "",
      text: Enum.map_join(assigns.segs, &elem(&1, 0)))
    ~M"""
    <.dynamic_tag tag_name={@field.tag} {@field.attrs} data-col={@col} style={"--field-column: #{@col + 1}; --field-width: #{@width}"} class={Enum.join(Enum.reject([@field.class, if(@uniform, do: @face_class)], &(&1 in [nil, ""])), " ")}><%= if @uniform do %>{@text}<% else %><.seg :for={{{txt, cls}, sx} <- Enum.with_index(@segs)} id={"#{@id_prefix}-#{sx}"} txt={txt} cls={cls} base={@base} win={@win} /><% end %></.dynamic_tag>
    """
  end

  # Wrap existing lines without introducing layout boxes or replacing text nodes.
  defp peek_text(assigns) do
    ~M"""
    <.dynamic_tag tag_name={block_root(Map.get(@node, :text_root)).tag}
      {block_root(Map.get(@node, :text_root)).attrs} class="peek-text">
      <%= for group <- semantic_line_groups(@node.lines, @node.semantic_records) do %>
        <.dynamic_tag tag_name={group.tag} {group.attrs} class="semantic-record">
          <c-text :for={ln <- group.lines}
            class={"line line-content #{if group.direct, do: "semantic-direct"}"}>
            <.semantic_line id_prefix={"peek-#{@node.id}-#{ln.num}"} segs={ln.segs}
              start={ln.start} fields={group.fields} base={@node.buffer} win={@node.id} direct={group.direct} />
          </c-text>
        </.dynamic_tag>
      <% end %>
    </.dynamic_tag>
    """
  end

  defp semantic_line_groups(lines, records) do
    records = for [start, stop, pl] <- records || [], is_integer(start) and is_integer(stop), do: {start, stop, block_view(pl)}
    {tagged, _} = Enum.map_reduce(lines, records, fn line, remaining ->
      remaining = Enum.drop_while(remaining, fn {_, stop, _} -> stop <= line.start end)
      block = case remaining do
        [{start, _, block} | _] when start <= line.start -> Map.put(block, :record_start, start)
        _ -> %{tag: "c-group", attrs: [], fields: [], direct: false}
      end
      {{block, line}, remaining}
    end)
    tagged
    |> Enum.chunk_by(fn {block, _} -> {block.tag, block.attrs, Map.get(block, :record_start)} end)
    |> Enum.map(fn [{block, _} | _] = chunk ->
      %{tag: block.tag, attrs: block.attrs, fields: block.fields, direct: block.direct, lines: Enum.map(chunk, &elem(&1, 1))}
    end)
  end

  defp block_root(pl) do
    block = block_view(pl || [])
    %{tag: if(block.tag == "div", do: "c-buffer", else: block.tag), attrs: block.attrs}
  end

  defp block_view(pl) do
    tag = pget(pl, "tag") || "div"

    %{
      tag: if(tag in @block_tags, do: tag, else: "div"),
      direct: pget(pl, "layout") == "columns",
      fields: for([a, b, field] <- pget(pl, "fields") || [], is_integer(a) and is_integer(b) and a < b, do: {a, b, block_view(field)}),
      class: pget(pl, "class") || "",
      anchor: falsy(pget(pl, "anchor")),
      lines: falsy(pget(pl, "lines")),
      mark: falsy(pget(pl, "mark")),
      click: falsy(pget(pl, "click")),
      text: falsy(pget(pl, "text")),
      segs: for([c, t | _] <- pget(pl, "segs") || [], do: {c, t}),
      semantic_segs: for([c, t | tags] <- pget(pl, "segs") || [], do: {c, t, if(List.first(tags) in @block_tags, do: List.first(tags), else: "c-text")}),
      attrs: block_attrs(pget(pl, "attrs") || []),
      children: Enum.map(pget(pl, "children") || [], &block_view/1)
    }
  end

  defp block_attrs(attrs) when is_list(attrs) do
    for [name, value] <- attrs,
        is_binary(name) and name in @block_attrs,
        is_binary(value) or is_number(value),
        do: {name, to_string(value)}
  end

  defp block_attrs(_), do: []

  defp pget([{:sym, k}, v | _], k), do: v
  defp pget([_, _ | rest], k), do: pget(rest, k)
  defp pget(_, _), do: nil

  defp falsy(false), do: nil
  defp falsy(v), do: v

  # A table always shrinks to the width it is given, and then clips what
  # does not fit. So the scrollbar must sit on an element OUTSIDE the
  # table. The renderer emits a bare <table>; give each one a box to scroll in.
  defp wrap_tables(html) do
    html
    |> String.replace(~r/<table(?=[\s>])/, ~s(<div class="ag-table"><table))
    |> String.replace("</table>", "</table></div>")
  end

  # the input region: [live text][cursor when point is home]
  defp ag_input(leaf, ag) do
    live_start = ag.input_start
    live = safe_slice(leaf.text, live_start, byte_size(leaf.text))

    # A restored window can carry an old transcript point. Rich chat hides
    # that position, so draw the caret at the input end until Scheme repairs it.
    rel =
      if leaf.point >= live_start do
        (leaf.point - live_start) |> min(byte_size(live)) |> then(&Text.floor_utf8(live, &1))
      else
        byte_size(live)
      end

    rest = binary_part(live, rel, byte_size(live) - rel)

    {pre, cur, post} =
      case String.next_grapheme(rest) do
        nil -> {live, " ", ""}
        {g, more} -> {binary_part(live, 0, rel), g, more}
      end

    %{pre: pre, cur: cur, post: post}
  end

  @doc false
  # Preview folds keep source byte offsets stable. Hidden lines become spaces.
  # A closing fence stays present so the Markdown tree remains valid.
  defp preview_fold_source("markdown", text, point, mark, hidden) do
    folded =
      text
      |> String.split("\n", trim: false)
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {line, index} ->
        if MapSet.member?(hidden, index) and
             not Regex.match?(~r/^\s*(?:```|~~~)/, line) do
          String.duplicate(" ", byte_size(line))
        else
          line
        end
      end)

    visible_point = preview_fold_point(text, point, hidden)

    visible_mark =
      if is_integer(mark), do: preview_fold_point(text, mark, hidden), else: mark

    {folded, visible_point, visible_mark}
  end

  defp preview_fold_source(_mode, text, point, mark, _hidden),
    do: {text, point, mark}

  defp preview_fold_point(text, point, hidden) do
    line = Compos.Core.Text.line_index(text, point)

    if MapSet.member?(hidden, line) do
      first = preview_first_hidden_line(hidden, line)
      starts = [0 | Enum.map(:binary.matches(text, "\n"), fn {at, _} -> at + 1 end)]
      max(Enum.at(starts, first) - 1, 0)
    else
      point
    end
  end

  defp preview_first_hidden_line(hidden, line) when line > 0 do
    if MapSet.member?(hidden, line - 1),
      do: preview_first_hidden_line(hidden, line - 1),
      else: line
  end

  defp preview_first_hidden_line(_hidden, 0), do: 0

  # The page is Markdown.Html's; the LiveView keeps the parse cache.
  # Parsing a document costs a hundred times what drawing it does, and the
  # tree does not change when the caret moves. So the tree is cached against
  # the buffer's version: a keystroke that moves point redraws and nothing
  # more, and only an edit parses again.
  defp render_preview("markdown" = rm, leaf, pt, mark, faces, cache) do
    {text, pt, mark} =
      preview_fold_source(rm, leaf.text, pt, mark, leaf.hidden_lines)

    leaf = %{leaf | text: text}
    {tree, cache} = md_tree(leaf, {leaf.buffer, leaf.version, leaf.hidden_lines}, cache)

    html =
      Compos.Core.Markdown.Html.document(
        leaf.text,
        pt,
        mark,
        faces,
        preview_opts(leaf.buffer) ++
          [
            tree: tree,
            overlays: leaf.overlays,
            whitespace: Compos.Core.Buffer.get_local(leaf.buffer, "whitespace-mode") == true,
            hidden_lines: leaf.hidden_lines
          ]
      )

    {html, cache}
  end

  defp render_preview(rm, leaf, pt, mark, faces, cache) do
    {text, pt, mark} = preview_fold_source(rm, leaf.text, pt, mark, leaf.hidden_lines)
    {preview_doc(rm, text, pt, mark, faces, leaf.preview_authored, leaf.overlays), cache}
  end

  # What only the web client knows: how a local path becomes a URL the
  # page can load, and how an X post becomes a card.
  defp preview_opts(buffer) do
    [
      base_dir: preview_dir(buffer),
      csv_source: csv_source_reader(buffer),
      local_url: &Compos.Ui.LocalImage.url/1,
      tweet_card: &Compos.Ui.Oembed.card/1
    ]
  end

  @doc """
  The Earmark page (`Compos.Core.Markdown.Classic`) with this client's
  image and card hooks: the renderer of a home with no Markdown grammar.
  """
  def preview_doc(rm, text, point, faces, authored),
    do: preview_doc(rm, text, point, nil, faces, authored, [])

  def preview_doc(rm, text, point, mark, faces, authored),
    do: preview_doc(rm, text, point, mark, faces, authored, [])

  def preview_doc(rm, text, point, mark, faces, authored, overlays),
    do: preview_doc(rm, text, point, mark, faces, authored, overlays, [])

  def preview_doc(rm, text, point, mark, faces, authored, overlays, opts) do
    ui = [local_url: &Compos.Ui.LocalImage.url/1, tweet_card: &Compos.Ui.Oembed.card/1]
    Compos.Core.Markdown.Classic.preview_doc(rm, text, point, mark, faces, authored, overlays, Keyword.merge(ui, opts))
  end

  defp csv_source_reader(buffer) do
    fn target ->
      case File.read(csv_preview_path(buffer, target)) do
        {:ok, text} -> text
        _ -> nil
      end
    end
  end

  defp csv_preview_path(buffer, target), do: Path.expand(target, preview_dir(buffer))

  # The document's own directory. A relative link is written relative to the
  # file it sits in, so that is what it resolves against.
  defp preview_dir(buffer) do
    case Compos.Core.Buffer.path(buffer) do
      path when is_binary(path) -> Path.dirname(path)
      _ -> Compos.Core.Buffer.get_local(buffer, "default-directory") || File.cwd!()
    end
  end

  defp md_tree(leaf, tree_key, cache) do
    case cache[{:md_tree, leaf.id}] do
      {^tree_key, tree} ->
        {tree, cache}

      _ ->
        case Compos.Core.Markdown.parse(Compos.Core.Markdown.Html.overlay_source(leaf.text, leaf.overlays)) do
          {:ok, tree} -> {tree, Map.put(cache, {:md_tree, leaf.id}, {tree_key, tree})}
          {:error, _} -> {nil, cache}
        end
    end
  end

  # The mode line's facts, as Scheme built them: a list of (KEY VALUE TONE
  # RANK). A row of another shape is skipped, never a crash in the render.
  defp ml_facts(%{modeline_facts: facts}) when is_list(facts) do
    for [k, v, tone, rank] <- facts,
        do: {to_string(k), to_string(v), to_string(tone), to_string(rank)}
  end

  defp ml_facts(_node), do: []

  # the modeline names the buffer the short way; the tooltip keeps the
  # absolute path. Scheme decides what short means (project.scm).
  # The buffer-name grammar (editor.scm) draws the name: Scheme names the
  # classes and the client draws one span each. A buffer whose dashboard
  # has not synced yet carries no segments, and shows the plain name.
  defp ml_segs(%{modeline_name_segments: segs}) when is_list(segs) do
    for [c, t] <- segs, is_binary(c), is_binary(t), do: {c, t}
  end

  defp ml_segs(_), do: []

  defp ml_bytes(text) do
    b = Kernel.byte_size(text)

    cond do
      b >= 1_048_576 -> "#{Float.round(b / 1_048_576, 1)} MB"
      b >= 1024 -> "#{Float.round(b / 1024, 1)} kB"
      true -> "#{b} B"
    end
  end

  defp pct(%{top: 0, rows: rows, total_lines: total}) when total <= rows, do: "All"
  defp pct(%{top: 0}), do: "Top"
  defp pct(%{top: top, rows: rows, total_lines: total}) when top + rows >= total, do: "Bot"

  defp pct(%{top: top, total_lines: total}),
    do: "#{min(div(top * 100, max(total - 1, 1)), 99)}%"

  # popup anchor column in ch units (monospace): graphemes from line start
  # to the completion region start
  defp completion_doc(candidate) do
    case List.keyfind(Map.get(candidate, :facts, []), "Documentation", 0) do
      {_, doc} -> doc
      nil -> "No documentation available."
    end
  end

  defp pop_col(text, line_start, comp_start) do
    len = comp_start |> max(line_start) |> min(byte_size(text))
    text |> binary_part(line_start, len - line_start) |> String.length()
  end

  @impl true
  def render(assigns), do: Compos.Ui.Representation.live(__MODULE__, assigns)

end
