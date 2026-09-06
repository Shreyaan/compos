defmodule Compos.Ui.MobileLiveTest do
  @moduledoc """
  The handheld client, driven the way the phone drives it: every gesture
  arrives as a key or a named event, and the page is read back as HTML.
  Nothing here names a production binding; the chord test binds its own
  key under <f9>.
  """

  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Compos.Ui.Endpoint

  defp hook(view, event, payload) do
    view |> element("#hh") |> render_hook(event, payload)
  end

  # a chord goes through dispatch-keys, which queues the keys behind the
  # event that asked for them; the page shows the result a moment later
  defp eventually(view, selector, text, tries \\ 40) do
    cond do
      has_element?(view, selector, text) -> true
      tries == 0 -> false
      true -> Process.sleep(25); render(view); eventually(view, selector, text, tries - 1)
    end
  end

  setup do
    Compos.Core.Editor.minibuffer_close()
    Compos.Core.Editor.completion_dismiss()
    Compos.Core.Editor.set_pending([])
    Compos.Core.Editor.set_total_rows(40)
    Compos.Core.Editor.delete_other_windows()
    Compos.Core.Editor.set_window_buffer("hh-test-#{System.unique_integer([:positive])}")
    {:ok, conn: build_conn()}
  end

  test "mounts one window with a modeline, a composer, a tab rail, and the chord key", %{conn: conn} do
    {:ok, view, html} = live(conn, "/m")
    assert has_element?(view, "#hh > .hh-modeline")
    assert has_element?(view, "#hh > .hh-composer #composer")
    assert has_element?(view, "#hh > .hh-tabs")
    assert has_element?(view, "#chord-key")
    assert html =~ "hh-test-"
    refute has_element?(view, ".hh-fan")
  end

  test "the fan opens on the prefixes Scheme names, and a prefix latches into its bindings", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    {:ok, _} = Compos.Core.Session.eval(~s{(global-set-key "<f9> q" "keyboard-quit")})
    on_exit(fn -> Compos.Core.Session.eval(~s{(global-unset-key "<f9> q")}) end)

    hook(view, "fan", %{"open" => true})
    assert has_element?(view, ".hh-fan .hh-arc[data-lvl='1']")

    # latch a prefix this test owns: the frame's pending keys become the
    # modeline badge and the fan shows what hangs under it
    hook(view, "arc", %{"k" => "<f9>", "lvl" => "1"})
    assert has_element?(view, ".hh-ml-pending", "<f9>-")
    assert has_element?(view, ".hh-fan .hh-arc[data-lvl='2'][data-arc='q']", "keyboard-quit")

    # the scrim is C-g: pending clears, the fan closes
    hook(view, "fan_quit", %{})
    refute has_element?(view, ".hh-fan")
    refute has_element?(view, ".hh-ml-pending")
  end

  test "a prompt renders as a sheet and a tap on a row accepts it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")

    {:ok, _} =
      Compos.Core.Session.eval(
        ~s{(minibuffer-read "Pick: " (list "alpha" "beta" "gamma") (lambda (s) (message (string-append "picked " s))))}
      )

    html = render(view)
    assert html =~ "hh-sheet"
    assert has_element?(view, "#hh[data-mb='true']")
    assert has_element?(view, ".hh-row", "beta")

    hook(view, "cand", %{"i" => 2})
    refute has_element?(view, ".hh-sheet")
    assert has_element?(view, ".hh-echo", "picked gamma")
  end

  test "the composer sends a chord through the keymap and a command by name", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    {:ok, _} = Compos.Core.Session.eval(~s{(global-set-key "<f9> m" "keyboard-quit")})
    on_exit(fn -> Compos.Core.Session.eval(~s{(global-unset-key "<f9> m")}) end)

    hook(view, "compose", %{"text" => "<f9> m"})
    assert eventually(view, ".hh-echo", "Quit")

    hook(view, "compose", %{"text" => "M-x hh-no-such-command"})
    assert has_element?(view, ".hh-echo", "No command named hh-no-such-command")
  end

  test "the tab rail is the groups, and a tap lands in the group's chat", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    buf = Compos.Core.Editor.current_buffer()
    {:ok, g} = Compos.Core.Session.eval(~s{(group-ensure! "#{buf}")})
    g = String.trim(g, "\"")
    render(view)
    hook(view, "tab", %{"buf" => g})
    assert has_element?(view, ".hh-tab.on")
    assert has_element?(view, ".hh-ml-mode", "chat-mode")
  end

  test "the fan under a prefix follows Scheme's cut and offers the rest", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    {:ok, _} = Compos.Core.Session.eval(~s{(set! handheld-fan-limit 2)})

    for k <- ~w(a b c d) do
      {:ok, _} = Compos.Core.Session.eval(~s{(global-set-key "<f9> #{k}" "keyboard-quit")})
    end

    on_exit(fn ->
      Compos.Core.Session.eval(~s{(set! handheld-fan-limit 7)})
      for k <- ~w(a b c d), do: Compos.Core.Session.eval(~s{(global-unset-key "<f9> #{k}")})
    end)

    hook(view, "fan", %{"open" => true})
    hook(view, "arc", %{"k" => "<f9>", "lvl" => "1"})
    assert has_element?(view, ".hh-arc[data-lvl='2'][data-arc='a']")
    assert has_element?(view, ".hh-arc[data-lvl='2'][data-arc='b']")
    refute has_element?(view, ".hh-arc[data-arc='c']")
    assert has_element?(view, ".hh-arc[data-more='1']", "2 more")

    hook(view, "fan_all", %{})
    assert has_element?(view, ".hh-fan-row[data-arc='d']")
    hook(view, "fan_quit", %{})
  end

  test "the rail moves point to the line the drag names", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    buf = Compos.Core.Editor.current_buffer()
    Compos.Core.Buffer.insert(buf, "one\ntwo\nthree\nfour\nfive\n")
    hook(view, "rail", %{"frac" => 1.0})
    assert Compos.Core.Buffer.line_of(buf, Compos.Core.Buffer.point(buf)) == 6
    hook(view, "rail", %{"frac" => 0.0})
    assert Compos.Core.Buffer.point(buf) == 0
  end
end
