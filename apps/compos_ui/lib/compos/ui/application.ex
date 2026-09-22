defmodule Compos.Ui.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # server generation id: clients that reconnect across a restart detect the
    # mismatch and full-reload, so stale CSS/JS never renders new markup
    :persistent_term.put(:compos_boot_id, Integer.to_string(System.system_time(:millisecond)))

    # the app origin's password, new on every boot: an app URL from the last
    # run reaches nothing
    :persistent_term.put(
      :compos_app_token,
      :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    )

    # the address this editor answers on. Scheme reads it through
    # (editor-url) to write a buffer link; compos_core must not depend on
    # this app, so the value travels as a term, not as a call.
    :persistent_term.put(:compos_editor_url, "http://localhost:#{http_port()}")

    children =
      [
        {Phoenix.PubSub, name: Compos.Ui.PubSub},
        Compos.Ui.Oembed,
        Compos.Ui.Endpoint
      ] ++ app_server()

    Supervisor.start_link(children, strategy: :one_for_one, name: Compos.Ui.Supervisor)
  end

  defp http_port do
    Application.get_env(:compos_ui, Compos.Ui.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port, 4004)
  end

  # A second origin, on loopback, that serves previewed apps and nothing
  # else. `app_port: nil` (the test env) leaves it off; the router is a
  # plain Plug, so the tests call it without a socket.
  defp app_server do
    case Application.get_env(:compos_ui, :app_port) do
      nil ->
        []

      port ->
        [
          # the fixed id lets Compos.Core.Daemon.restart_listener/1 find and
          # bounce this child by name
          %{
            id: :compos_app_server,
            start: {__MODULE__, :start_app_listener, [port]}
          }
        ]
    end
  end

  @doc """
  Start the previewed-apps origin, or say why it is not there.

  A busy port is not a reason to have no editor. This origin is a second,
  optional listener on loopback: it serves previewed apps and nothing
  else. Started as a plain Bandit child, a port another program already
  held failed this supervisor, failed the application, and left the user
  with no editor at all and an `:eaddrinuse` about a listener they had
  never heard of. `:ignore` tells the supervisor there is no child here,
  which is the truth, and the editor comes up.
  """
  def start_app_listener(port) do
    case Bandit.start_link(
           plug: Compos.Ui.AppServer,
           scheme: :http,
           ip: {127, 0, 0, 1},
           port: port,
           startup_log: false
         ) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.error(
          "app server: cannot listen on 127.0.0.1:#{port} (#{inspect(reason)}). " <>
            "The editor runs without it; previewed apps have no origin until the " <>
            "port is free. M-x restart-listener brings it back."
        )

        :ignore
    end
  end
end
