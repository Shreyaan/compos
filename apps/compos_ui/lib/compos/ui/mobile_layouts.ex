defmodule Compos.Ui.MobileLayouts do
  @moduledoc """
  The root layout of the handheld client: its stylesheet and its one hook.

  The desktop layout is not shared. The phone has its own chrome (a
  modeline, a composer, a tab rail, a chord key) and its own gestures,
  and the two files stay apart so neither grows conditions for the other.
  The theme still comes from the faces: the design's tokens map onto the
  face variables the daemon sends.
  """
  use Phoenix.Component

  def root(assigns) do
    assigns = assign_new(assigns, :page_title, fn -> "compos" end)

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, maximum-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <meta name="boot-id" content={:persistent_term.get(:compos_boot_id, "dev")} />
        <meta name="apple-mobile-web-app-capable" content="yes" />
        <meta name="apple-mobile-web-app-status-bar-style" content="default" />
        <meta name="theme-color" content="#efece2" />
        <title>{@page_title}</title>
        <link rel="manifest" href="/manifest.webmanifest" />
        <link rel="icon" type="image/png" href="/icons/compos-192.png" />
        <link rel="apple-touch-icon" href="/icons/compos-192.png" />
        <script>
          window.addEventListener("phx:page-loading-stop", () => {
            const bg = getComputedStyle(document.documentElement).getPropertyValue("--default-bg").trim();
            const meta = document.querySelector('meta[name="theme-color"]');
            if (bg && meta) meta.setAttribute("content", bg);
          });
        </script>
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link
          href="https://fonts.googleapis.com/css2?family=Spectral:ital,wght@0,300;0,400;0,500;0,600;1,400&family=IBM+Plex+Mono:wght@400;500;600&display=swap"
          rel="stylesheet"
        />
        <style>
          :root {
            --font-mono: 'IBM Plex Mono', ui-monospace, Menlo, monospace;
            --font-serif: Spectral, Georgia, serif;
          }
          /* the design's tokens, each one a face variable the daemon sends */
          .hh {
            --paper: var(--default-bg, #efece2);
            --panel: var(--window-inactive-bg, var(--modeline-bg, #f4f1e7));
            --panel-dim: var(--modeline-bg, #eae6d9);
            --ink: var(--default-fg, #17160f);
            --ink-soft: var(--window-fg, var(--default-fg, #403d31));
            --faint: var(--dim-fg, #7d7a6c);
            --dim: var(--linenum-fg, var(--dim-fg, #a19d8d));
            --rule: var(--border-bg, #cfcabb);
            --rule-soft: var(--border-bg, #ddd8c9);
            --indigo: var(--accent-fg, #2c4a91);
            --green: var(--ok-fg, #2e6b45);
            --amber: var(--warn-fg, #8a5a1e);
            --red: var(--alert-fg, #a83a2b);
            --sand: var(--region-bg, #e8d5ac);
            --safe-top: env(safe-area-inset-top, 0px);
            --safe-bottom: env(safe-area-inset-bottom, 0px);
          }
          * { box-sizing: border-box; margin: 0; padding: 0; }
          html, body { height: 100%; }
          body {
            background: var(--default-bg, #efece2);
            color: var(--default-fg, #17160f);
            font-family: var(--font-mono);
            font-size: 13px;
            overflow: hidden;
            -webkit-font-smoothing: antialiased;
            -webkit-text-size-adjust: 100%;
            overscroll-behavior: none;
          }
          @keyframes hh-blink { 0%, 49% { opacity: 1 } 50%, 100% { opacity: 0 } }

          .hh {
            position: relative; height: 100dvh; width: 100vw;
            display: flex; flex-direction: column;
            background: var(--paper); color: var(--ink); overflow: hidden;
          }
          /* no text selection on the chrome. Not on the root: an input under
             a -webkit-user-select:none ancestor never raises the keyboard
             on iOS. */
          .hh-modeline, .hh-tabs, .hh-key, .hh-fan, .hh-chips, .hh-rail, .hh-sheet-head, .hh-sheet-legend {
            user-select: none; -webkit-user-select: none;
          }
          .hh-splash { display: flex; align-items: center; justify-content: center; height: 100%; opacity: .5; }
          .hh-spacer { flex: 1; }

          /* ── the modeline: one line, always ─────────────────────── */
          .hh-modeline {
            flex: none; display: flex; align-items: center; gap: 8px;
            padding: calc(7px + var(--safe-top)) 12px 7px;
            background: var(--panel); border-bottom: 1px solid var(--rule);
            font-size: 11px; letter-spacing: .04em; white-space: nowrap; overflow: hidden;
          }
          .hh-ml-flags { color: var(--faint); }
          .hh-ml-name { font-weight: 600; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
          .hh-ml-mode { color: var(--faint); }
          .hh-ml-info { color: var(--indigo); overflow: hidden; text-overflow: ellipsis; max-width: 34vw; }
          .hh-ml-pending {
            padding: 2px 7px; background: var(--ink); color: var(--paper);
            font-weight: 600; letter-spacing: .08em;
          }

          /* ── the body: the rail and the one window ──────────────── */
          .hh-body { flex: 1; min-height: 0; display: flex; }
          .hh-rail {
            flex: none; width: 24px; position: relative;
            border-right: 1px solid var(--rule-soft); background: var(--panel-dim);
            display: flex; flex-direction: column; align-items: center; justify-content: space-between;
            padding: 6px 0; touch-action: none;
          }
          .hh-rail-k { font-size: 8.5px; color: var(--dim); }
          .hh-rail-w { font-size: 8.5px; color: var(--dim); writing-mode: vertical-rl; letter-spacing: .16em; text-transform: uppercase; }
          .hh-rail-mark { position: absolute; left: 3px; right: 3px; height: 3px; background: var(--indigo); }
          .hh-content { flex: 1; min-width: 0; min-height: 0; overflow: auto; -webkit-overflow-scrolling: touch; }
          .hh-lines { padding: 10px 12px 16px; font-family: var(--font-mono); font-size: 13px; line-height: 1.5; }
          .hh-line { display: flex; gap: 8px; padding: 1px 0 1px 6px; margin-left: -6px; border-left: 2px solid transparent; }
          .hh-line.cur { background: var(--panel-dim); border-left-color: var(--indigo); }
          .hh-linenum { flex: none; width: 3ch; text-align: right; color: var(--dim); font-size: 10px; padding-top: 3px; }
          .hh-line-text { flex: 1; min-width: 0; white-space: pre-wrap; overflow-wrap: anywhere; }
          .hh-line-text .cursor { background: var(--cursor-bg, var(--ink)); color: var(--paper); }
          .hh-empty { padding: 20px 4px; color: var(--faint); font-size: 11px; }
          .hh-preview { width: 100%; height: 100%; border: 0; background: var(--paper); }

          /* the transcript, drawn for a phone: serif answers, mono asks */
          .agent-view { display: flex; flex-direction: column; --ag-base: 13px; font-size: var(--ag-base); }
          .ag-scroll { flex: 1; min-height: 0; overflow-y: auto; padding: 12px 14px 8px; -webkit-overflow-scrolling: touch; }
          .ag-label {
            font-family: var(--font-mono); font-size: 9.5px; letter-spacing: .16em; text-transform: uppercase;
            color: var(--faint); flex-shrink: 0; padding-top: 3px;
          }
          .ag-user { display: flex; gap: 10px; margin: 12px 0; padding-left: 8px; border-left: 2px solid var(--rule); }
          .ag-user-text { min-width: 0; font-family: var(--font-mono); font-size: 13px; line-height: 1.5; color: var(--ink-soft); white-space: pre-wrap; overflow-wrap: anywhere; }
          .ag-queued { opacity: .6; }
          .ag-prose { font-family: var(--font-serif); font-size: 16px; line-height: 1.5; margin: 12px 0; text-wrap: pretty; }
          .ag-prose p { margin: 6px 0; }
          .ag-prose ul, .ag-prose ol { margin: 6px 0 6px 1.3em; }
          .ag-prose code, .ag-prose pre { font-family: var(--font-mono); font-size: 12px; background: var(--panel-dim); }
          .ag-prose code { padding: 1px 4px; }
          .ag-prose pre { padding: 8px 10px; overflow-x: auto; margin: 6px 0; }
          .ag-prose pre code { background: none; padding: 0; }
          .ag-prose a { color: var(--indigo); }
          .ag-table { overflow-x: auto; margin: 8px 0; }
          .ag-prose table { border-collapse: collapse; font-size: 13px; }
          .ag-prose th, .ag-prose td { border: 1px solid var(--rule); padding: 4px 8px; text-align: left; }
          .ag-tool, .ag-thought { margin: 8px 0; border: 1px solid var(--rule); background: var(--panel); font-size: 11px; }
          .ag-tool summary, .ag-thought summary { list-style: none; display: flex; align-items: center; gap: 8px; padding: 8px 10px; cursor: pointer; }
          .ag-tool summary::-webkit-details-marker { display: none; }
          .ag-chevron { color: var(--faint); transition: transform .12s; }
          .ag-tool[open] .ag-chevron { transform: rotate(90deg); }
          .ag-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--faint); flex: none; }
          .ag-dot.running { background: var(--amber); }
          .ag-dot.done { background: var(--green); }
          .ag-dot.failed { background: var(--red); }
          .ag-kind { font-size: 9px; letter-spacing: .14em; text-transform: uppercase; color: var(--faint); }
          .ag-summary-copy { min-width: 0; flex: 1; display: flex; flex-direction: column; gap: 2px; }
          .ag-title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .ag-tool-name { color: var(--faint); }
          .ag-arg { margin-left: 6px; color: var(--indigo); font-weight: 600; }
          .ag-preview { color: var(--faint); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .ag-tstatus, .ag-duration { color: var(--faint); font-size: 10px; flex: none; }
          .ag-tstatus.failed { color: var(--red); }
          .ag-body { padding: 8px 10px; border-top: 1px solid var(--rule-soft); white-space: pre-wrap; overflow-wrap: anywhere; font-family: var(--font-mono); font-size: 11px; max-height: 40vh; overflow: auto; }
          .ag-thought summary { color: var(--faint); }
          .ag-thought-text { padding: 6px 10px; white-space: pre-wrap; color: var(--faint); font-size: 11px; }
          .ag-plan { margin: 8px 0; padding: 8px 10px; border: 1px solid var(--rule); font-size: 12px; }
          .ag-perm, .ag-question { margin: 10px 0; padding: 10px; background: var(--sand); color: var(--amber); font-size: 12px; }
          .ag-perm { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
          .ag-perm-title { flex: 1 1 100%; }
          .ag-question-title { color: var(--ink); font-weight: 600; }
          .ag-question-answers { display: flex; flex-wrap: wrap; gap: 7px; margin-top: 10px; }
          .ag-question-hint { color: var(--faint); font-size: 10px; margin-top: 6px; }
          .ag-btn {
            padding: 9px 12px; border: 1px solid var(--ink); background: var(--paper); color: var(--ink);
            font-family: var(--font-mono); font-size: 10.5px; letter-spacing: .1em; text-transform: uppercase;
          }
          .ag-btn.primary, .ag-btn.answer { background: var(--ink); color: var(--paper); }
          .ag-meta, .ag-status { color: var(--faint); font-size: 10.5px; margin: 6px 0; }
          .ag-queued-row { margin: 4px 14px; }
          .ag-activity { display: flex; align-items: center; gap: 8px; padding: 6px 14px 8px; font-size: 10.5px; color: var(--faint); }
          .hh-blink { display: inline-block; width: 7px; height: 14px; background: var(--indigo); animation: hh-blink .9s step-end infinite; }

          /* ── the composer ───────────────────────────────────────── */
          .hh-composer { flex: none; background: var(--panel); border-top: 1px solid var(--rule); z-index: 6; }
          .hh-chips { display: flex; gap: 6px; padding: 7px 10px 3px; overflow-x: auto; scrollbar-width: none; }
          .hh-chips::-webkit-scrollbar { display: none; }
          .hh-chip {
            flex: none; display: flex; align-items: baseline; gap: 7px; padding: 7px 10px;
            border: 1px solid var(--rule); background: var(--paper); font-size: 11px;
          }
          .hh-chip:active { background: var(--sand); }
          .hh-chip-label { font-family: var(--font-serif); font-size: 13.5px; }
          .hh-chip-chord { color: var(--indigo); font-size: 9.5px; }
          .hh-input-row { display: flex; align-items: center; gap: 8px; padding: 6px 10px 6px; }
          .hh-prompt { flex: none; color: var(--indigo); font-size: 12px; font-weight: 600; max-width: 30vw; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .hh-input {
            flex: 1; min-width: 0; background: transparent; border: 0; outline: none;
            font-family: var(--font-mono); font-size: 16px; color: var(--ink);
            user-select: text; -webkit-user-select: text; padding: 8px 0;
          }
          .hh-input::placeholder { color: var(--dim); }
          .hh-send {
            flex: none; padding: 9px 12px; background: var(--panel-dim); color: var(--faint);
            font-size: 10.5px; letter-spacing: .12em; text-transform: uppercase;
          }
          .hh-send.armed { background: var(--ink); color: var(--paper); }
          .hh-echo {
            padding: 0 10px 7px; font-size: 10px; color: var(--faint); min-height: 17px;
            overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
          }
          .hh-echo.err { color: var(--red); }

          /* ── the tab rail ───────────────────────────────────────── */
          .hh-tabs {
            flex: none; height: calc(54px + var(--safe-bottom)); padding-bottom: var(--safe-bottom);
            display: flex; align-items: stretch; overflow-x: auto; scrollbar-width: none;
            background: var(--panel-dim); border-top: 1px solid var(--rule); z-index: 6;
          }
          .hh-tabs::-webkit-scrollbar { display: none; }
          .hh-tab {
            flex: none; min-width: 104px; max-width: 46vw; padding: 8px 12px; border-right: 1px solid var(--rule-soft);
            display: flex; flex-direction: column; justify-content: center; gap: 3px; color: var(--faint);
          }
          .hh-tab.on { background: var(--paper); color: var(--ink); }
          .hh-tab-kind { font-size: 9px; letter-spacing: .14em; text-transform: uppercase; color: var(--indigo); }
          .hh-tab[data-kind="chat"] .hh-tab-kind { color: var(--indigo); }
          .hh-tab[data-kind="dir"] .hh-tab-kind { color: var(--green); }
          .hh-tab-title { font-family: var(--font-serif); font-size: 13.5px; line-height: 1.2; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

          /* ── the chord key and the keys panel ───────────────────── */
          .hh-scrim { position: absolute; inset: 0; background: rgba(10, 10, 12, .28); z-index: 10; }
          .hh-keys {
            position: absolute; left: 0; right: 0; bottom: var(--dock-h, 170px); z-index: 12;
            max-height: 62%; display: flex; flex-direction: column;
            background: var(--paper); border-top: 1px solid var(--ink);
            box-shadow: 0 -6px 18px rgba(10, 10, 12, .12);
          }
          .hh-keys-tabs {
            flex: none; display: flex; align-items: center; gap: 4px; padding: 8px 10px;
            border-bottom: 1px solid var(--rule); background: var(--panel);
            overflow-x: auto; scrollbar-width: none;
          }
          .hh-keys-tabs::-webkit-scrollbar { display: none; }
          .hh-keys-tab {
            flex: none; padding: 7px 10px; border: 1px solid var(--rule); background: var(--paper);
            font-size: 12px; font-weight: 600; letter-spacing: .04em; white-space: nowrap;
          }
          .hh-keys-tab small { margin-left: 5px; font-size: 9px; font-weight: 400; color: var(--faint); }
          .hh-keys-tab.on { background: var(--ink); color: var(--paper); border-color: var(--ink); }
          .hh-keys-tab.on small { color: var(--paper); opacity: .7; }
          .hh-keys-quit { flex: none; padding: 5px 10px; border: 1px solid var(--rule); font-size: 10.5px; letter-spacing: .1em; color: var(--faint); }
          .hh-keys-list { flex: 1; min-height: 0; overflow-y: auto; -webkit-overflow-scrolling: touch; }
          .hh-key-row { display: flex; align-items: center; gap: 12px; min-height: 52px; padding: 8px 14px; border-bottom: 1px solid var(--rule-soft); }
          .hh-key-row:active { background: var(--sand); }
          .hh-key-box { flex: none; min-width: 34px; padding: 4px 7px; border: 1px solid var(--rule); text-align: center; font-size: 12px; font-weight: 600; color: var(--indigo); white-space: nowrap; }
          .hh-key-cmd { font-family: var(--font-serif); font-size: 15.5px; line-height: 1.2; }
          .hh-key-doc { margin-top: 2px; font-size: 10.5px; color: var(--faint); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .hh-key {
            position: absolute; z-index: 14; right: 18px; bottom: calc(200px + var(--safe-bottom));
            width: 62px; height: 62px; border-radius: 31px;
            background: var(--sand); color: var(--ink); border: 1px solid var(--ink);
            display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 1px;
            box-shadow: 0 8px 22px rgba(10, 10, 12, .22); touch-action: none;
          }
          .hh-key.on { background: var(--ink); color: var(--paper); }
          .hh-key-glyph { font-size: 15px; font-weight: 600; letter-spacing: .02em; max-width: 58px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .hh-key-cap { font-size: 7.5px; letter-spacing: .12em; text-transform: uppercase; opacity: .72; white-space: nowrap; }

          /* ── sheets: a prompt or a transient ────────────────────── */
          /* a sheet ends where the composer starts: the field stays under
             the thumb, and typing there feeds the prompt */
          .hh-sheet-layer { position: absolute; left: 0; right: 0; top: 0; bottom: var(--dock-h, 170px); z-index: 20; display: flex; flex-direction: column; justify-content: flex-end; }
          .hh-composer.prompting { position: relative; z-index: 22; border-top-color: var(--ink); }
          .hh-sheet-scrim { flex: 1; background: rgba(10, 10, 12, .34); }
          .hh-sheet {
            flex: none; background: var(--paper); border-top: 1px solid var(--ink);
            max-height: 78%; display: flex; flex-direction: column;
            padding-bottom: calc(var(--safe-bottom) + 6px);
          }
          .hh-sheet-head { flex: none; display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-bottom: 1px solid var(--rule); background: var(--panel); }
          .hh-kicker { font-size: 10.5px; letter-spacing: .16em; text-transform: uppercase; color: var(--faint); }
          .hh-sheet-quit { padding: 5px 10px; border: 1px solid var(--rule); font-size: 10.5px; letter-spacing: .1em; color: var(--faint); }
          .hh-sheet-title { flex: none; padding: 12px 14px 0; font-family: var(--font-serif); font-size: 20px; line-height: 1.15; letter-spacing: -.4px; }
          .hh-sheet-hint { flex: none; padding: 5px 14px 10px; font-size: 11px; line-height: 1.5; color: var(--faint); }
          .hh-sheet-input { flex: none; display: flex; align-items: center; gap: 8px; padding: 8px 14px; border-top: 1px solid var(--rule-soft); border-bottom: 1px solid var(--rule-soft); font-size: 13px; }
          .hh-mb-input { white-space: pre; overflow: hidden; }
          .hh-mb-input .cursor { background: var(--ink); color: var(--paper); }
          .hh-count { font-size: 10px; color: var(--dim); }
          .hh-sheet-rows { flex: 1; min-height: 0; overflow: auto; -webkit-overflow-scrolling: touch; }
          .hh-sep { padding: 9px 14px 5px; background: var(--panel-dim); font-size: 9.5px; letter-spacing: .18em; text-transform: uppercase; color: var(--faint); }
          .hh-row, .hh-trow { display: flex; align-items: center; gap: 12px; min-height: 56px; padding: 10px 14px; border-bottom: 1px solid var(--rule-soft); }
          .hh-row:active, .hh-trow:active { background: var(--sand); }
          .hh-row.on { background: var(--panel); }
          .hh-row-box { flex: none; width: 26px; height: 26px; border: 1px solid var(--rule); display: flex; align-items: center; justify-content: center; font-size: 11px; color: var(--indigo); }
          .hh-row-main { flex: 1; min-width: 0; }
          .hh-row-label { font-family: var(--font-serif); font-size: 16px; line-height: 1.2; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .hh-row-sub { margin-top: 3px; font-size: 10.5px; color: var(--faint); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .hh-group-title { padding: 9px 14px 5px; background: var(--panel-dim); font-size: 9.5px; letter-spacing: .18em; text-transform: uppercase; color: var(--faint); }
          .hh-tchips { display: flex; flex-wrap: wrap; gap: 6px; padding: 0 14px 10px; }
          .hh-tchip { padding: 6px 10px; border: 1px solid var(--rule); font-size: 11px; }
          .hh-tchip.on { background: var(--ink); color: var(--paper); border-color: var(--ink); }
          .hh-trow.on { background: var(--panel); }
          .hh-tkey { flex: none; min-width: 24px; height: 24px; padding: 0 5px; border: 1px solid var(--rule); display: flex; align-items: center; justify-content: center; font-size: 11px; color: var(--indigo); }
          .hh-trow-desc { font-size: 10px; letter-spacing: .14em; text-transform: uppercase; color: var(--faint); }
          .hh-trow-value { margin-top: 3px; font-family: var(--font-serif); font-size: 16px; line-height: 1.2; }
          .hh-trow:not(:has(.hh-trow-value)) .hh-trow-desc { font-family: var(--font-serif); font-size: 15px; letter-spacing: 0; text-transform: none; color: var(--ink); }
          .hh-chev { flex: none; font-size: 13px; color: var(--faint); }
          .hh-detail { padding: 0 0 8px; }
          .hh-detail-row { display: flex; gap: 12px; padding: 5px 14px; font-size: 11px; }
          .hh-detail-k { flex: none; width: 92px; color: var(--faint); }
          .hh-detail-v { flex: 1; }
          .hh-detail-row.drift .hh-detail-v { color: var(--amber); }
          .hh-detail-row.dim { color: var(--dim); }
          .hh-detail-note { padding: 6px 14px; font-size: 10.5px; color: var(--faint); white-space: pre-line; }
          .hh-sheet-legend { flex: none; display: flex; flex-wrap: wrap; gap: 6px; padding: 10px 14px 4px; }
          .hh-legend { padding: 7px 10px; border: 1px solid var(--rule); font-size: 10.5px; color: var(--faint); }
          .hh-legend b { color: var(--indigo); font-weight: 600; }
        </style>
      </head>
      <body>
        {@inner_content}
        <script src="/phx/phoenix.min.js"></script>
        <script src="/lv/phoenix_live_view.min.js"></script>
        <script>
          const NAMED = {
            Enter: "RET", Backspace: "DEL", Tab: "TAB", Escape: "ESC", " ": "SPC",
            ArrowUp: "<up>", ArrowDown: "<down>", ArrowLeft: "<left>", ArrowRight: "<right>"
          };
          const keyOf = (ch) => NAMED[ch] || ch;

          const Hooks = {
            // the transcript component's hook: stay at the bottom while
            // the reader is there, and hand links to the server
            AgentScroll: {
              mounted() {
                this.stick = this.el.dataset.stick !== "false";
                this.scrollH = () => {
                  const s = this.el;
                  if (!s.isConnected || s.clientHeight === 0) return;
                  this.stick = s.scrollHeight - s.scrollTop - s.clientHeight < 40;
                  clearTimeout(this.report);
                  this.report = setTimeout(() => {
                    this.pushEvent("ag_stick", { buf: this.el.dataset.buf, stick: this.stick, top: Math.round(s.scrollTop) });
                  }, 250);
                };
                this.el.addEventListener("scroll", this.scrollH, { passive: true });
                this.linkH = (e) => {
                  const link = e.target.closest && e.target.closest("a[href]");
                  if (!link || !this.el.contains(link)) return;
                  const href = link.getAttribute("href") || "";
                  if (href === "" || href.startsWith("#")) return;
                  e.preventDefault();
                  this.pushEvent("preview_link", { win: parseInt(this.el.dataset.win, 10), href });
                };
                this.el.addEventListener("click", this.linkH);
                this.place();
              },
              updated() { if (this.el.dataset.buf !== this.buf) { this.buf = this.el.dataset.buf; this.stick = true; } if (this.stick) this.place(); },
              place() { const s = this.el; if (this.stick) s.scrollTop = s.scrollHeight; },
              destroyed() { this.el.removeEventListener("scroll", this.scrollH); this.el.removeEventListener("click", this.linkH); clearTimeout(this.report); }
            },
            Handheld: {
              mounted() {
                this.push = (ev, payload) => this.pushEvent(ev, payload);
                this.remember();
                this.bootCheck();
                this.viewport();
                this.dock();
                this.resizeH = () => { this.viewport(); this.dock(); };
                window.addEventListener("resize", this.resizeH);
                this.handleEvent("navigate", ({ url }) => { window.location.href = url; });
                this.bindKey();
                this.bindRail();
                this.bindComposer();
                this.bindTabs();
              },
              updated() {
                this.remember();
                this.bootCheck();
                this.dock();
                this.bindKey();
                this.bindRail();
                this.bindComposer();
                if (this.el.dataset.mb !== this.mbWas) {
                  this.mbWas = this.el.dataset.mb;
                  const input = document.getElementById("composer");
                  if (input) { input.value = ""; this.last = ""; this.arm(); }
                }
              },
              destroyed() { window.removeEventListener("resize", this.resizeH); },

              // the frame this tab holds, so a reload comes back to it
              remember() {
                const f = this.el.dataset.frame;
                if (f) { try { sessionStorage.setItem("compos-frame-m", f); } catch (e) {} }
              },
              // a daemon restart changes the boot id; this page belongs
              // to the old one and reloads
              bootCheck() {
                const meta = document.querySelector('meta[name="boot-id"]');
                const boot = meta && meta.getAttribute("content");
                if (boot && this.el.dataset.boot && boot !== this.el.dataset.boot) window.location.reload();
              },
              // how tall the composer and the tab rail are together, so a
              // sheet stops above them
              dock() {
                const c = this.el.querySelector(".hh-composer");
                const t = this.el.querySelector(".hh-tabs");
                const h = (c ? c.offsetHeight : 0) + (t ? t.offsetHeight : 0);
                if (h && h !== this.dockH) { this.dockH = h; this.el.style.setProperty("--dock-h", h + "px"); }
              },
              viewport() {
                const rows = Math.max(8, Math.floor((window.innerHeight - 260) / 19.5));
                if (rows !== this.rows) { this.rows = rows; this.push("viewport", { rows }); }
              },

              // ── the chord key: a tap opens the keys panel, a tap closes it ──
              bindKey() {
                const key = document.getElementById("chord-key");
                if (!key || key.dataset.bound) return;
                key.dataset.bound = "1";
                key.addEventListener("pointerdown", (e) => {
                  e.preventDefault();
                  this.push("fan", { open: !key.classList.contains("on") });
                });
              },

              // ── the tab rail: a tap is the group, a hold is its buffers ──
              // One listener on the rail, so re-rendered tabs need no
              // rebinding. A hold that moves is a scroll, not a press.
              bindTabs() {
                const rail = this.el.querySelector(".hh-tabs");
                if (!rail || rail.dataset.bound) return;
                rail.dataset.bound = "1";
                const cancel = () => { clearTimeout(this.holdT); this.holdT = null; };
                rail.addEventListener("pointerdown", (e) => {
                  const tab = e.target.closest && e.target.closest("[data-tab]");
                  if (!tab) return;
                  this.holdX = e.clientX; this.holdY = e.clientY; this.held = false;
                  cancel();
                  this.holdT = setTimeout(() => {
                    this.held = true;
                    this.push("tab_hold", { buf: tab.dataset.tab });
                  }, 450);
                });
                rail.addEventListener("pointermove", (e) => {
                  if (this.holdT && (Math.abs(e.clientX - this.holdX) > 8 || Math.abs(e.clientY - this.holdY) > 8)) cancel();
                });
                rail.addEventListener("pointerup", cancel);
                rail.addEventListener("pointercancel", cancel);
                // the tap that ends a hold is not a tap on the tab
                rail.addEventListener("click", (e) => {
                  if (this.held) { this.held = false; e.stopPropagation(); e.preventDefault(); }
                }, true);
                rail.addEventListener("contextmenu", (e) => e.preventDefault());
              },

              // ── the rail: a drag is point ──────────────────────────
              bindRail() {
                const rail = this.el.querySelector("[data-rail]");
                if (!rail || rail.dataset.bound) return;
                rail.dataset.bound = "1";
                const scrub = (e) => {
                  const r = rail.getBoundingClientRect();
                  const frac = Math.max(0, Math.min(1, (e.clientY - r.top) / r.height));
                  const now = Date.now();
                  if (this.railAt && now - this.railAt < 60) { this.railNext = frac; return; }
                  this.railAt = now;
                  this.push("rail", { frac });
                };
                rail.addEventListener("pointerdown", (e) => { e.preventDefault(); rail.setPointerCapture(e.pointerId); this.scrubbing = true; scrub(e); });
                rail.addEventListener("pointermove", (e) => { if (this.scrubbing) scrub(e); });
                const stop = () => {
                  this.scrubbing = false;
                  if (this.railNext != null) { this.push("rail", { frac: this.railNext }); this.railNext = null; }
                };
                rail.addEventListener("pointerup", stop);
                rail.addEventListener("pointercancel", stop);
              },

              // ── the composer: one field, three registers ───────────
              // While a prompt is up the field feeds the minibuffer one
              // key at a time, so the prompt narrows as the user types.
              // Otherwise RET sends the line to Scheme, which decides.
              arm() {
                const input = document.getElementById("composer");
                const send = document.getElementById("composer-send");
                if (send) send.classList.toggle("armed", !!(input && input.value));
              },
              bindComposer() {
                const input = document.getElementById("composer");
                const send = document.getElementById("composer-send");
                if (!input || input.dataset.bound) return;
                input.dataset.bound = "1";
                this.last = "";
                const submit = () => {
                  if (this.el.dataset.mb === "true") { this.push("key", { k: "RET" }); return; }
                  const text = input.value;
                  if (!text.trim()) return;
                  input.value = "";
                  this.last = "";
                  this.arm();
                  this.push("compose", { text });
                };
                input.addEventListener("keydown", (e) => {
                  if (e.key === "Enter") { e.preventDefault(); submit(); }
                  else if (e.key === "Escape") { e.preventDefault(); this.push("key", { k: "C-g" }); }
                  else if (this.el.dataset.mb === "true" && (e.key === "ArrowUp" || e.key === "ArrowDown" || e.key === "Tab")) {
                    e.preventDefault(); this.push("key", { k: keyOf(e.key) });
                  }
                });
                input.addEventListener("input", () => {
                  this.arm();
                  if (this.el.dataset.mb !== "true") return;
                  const now = input.value, was = this.last || "";
                  let common = 0;
                  while (common < now.length && common < was.length && now[common] === was[common]) common++;
                  const ks = [];
                  for (let i = common; i < was.length; i++) ks.push("DEL");
                  for (const ch of Array.from(now.slice(common))) ks.push(keyOf(ch));
                  this.last = now;
                  if (ks.length) this.push("keys", { ks });
                });
                if (send) send.addEventListener("click", submit);
              }
            }
          };

          const csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
            hooks: Hooks,
            params: () => ({
              _csrf_token: csrf,
              // the phone tab is its own frame, remembered per tab
              frame: sessionStorage.getItem("compos-frame-m")
            })
          });
          liveSocket.connect();
          if (liveSocket.disableDebug) liveSocket.disableDebug();
        </script>
      </body>
    </html>
    """
  end
end
