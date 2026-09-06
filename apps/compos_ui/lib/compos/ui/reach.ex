defmodule Compos.Ui.Reach do
  @moduledoc """
  Who may reach the editor port.

  The endpoint listens on every interface so a browser on the tailnet can
  open the editor, and this plug admits only two kinds of client: this
  machine (loopback) and the tailnet (Tailscale's 100.64.0.0/10 and
  fd7a:115c:a1e0::/48). Every other address gets 403 before the router.

  `local_origin?/1` is the same rule for a WebSocket Origin header: the
  page came from localhost, from this host's name, or from this host's
  MagicDNS name or tailnet address.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if allowed_ip?(conn.remote_ip) do
      conn
    else
      conn
      |> send_resp(403, "this editor answers loopback and the tailnet only")
      |> halt()
    end
  end

  @doc "True for loopback and for a Tailscale address."
  def allowed_ip?({127, _, _, _}), do: true
  def allowed_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # an IPv4 client on a dual-stack socket
  def allowed_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: allowed_ip?({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})

  # Tailscale's CGNAT range, 100.64.0.0/10
  def allowed_ip?({100, b, _, _}) when b >= 64 and b <= 127, do: true
  # Tailscale's IPv6 range, fd7a:115c:a1e0::/48
  def allowed_ip?({0xFD7A, 0x115C, 0xA1E0, _, _, _, _, _}), do: true
  def allowed_ip?(_), do: false

  @doc """
  True when a WebSocket Origin names this machine: a loopback spelling,
  this host's name, its MagicDNS name (HOST.*.ts.net), or one of its
  tailnet addresses.
  """
  def local_origin?(%URI{host: host}) when is_binary(host) do
    name = hostname()

    cond do
      host in ["localhost", "127.0.0.1", "[::1]", "::1"] -> true
      host == name -> true
      String.starts_with?(host, name <> ".") and String.ends_with?(host, ".ts.net") -> true
      true -> tailnet_address?(host)
    end
  end

  def local_origin?(_), do: false

  defp hostname do
    {:ok, name} = :inet.gethostname()
    name |> to_string() |> String.split(".") |> hd() |> String.downcase()
  end

  defp tailnet_address?(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> allowed_ip?(ip) and not loopback?(ip)
      _ -> false
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false
end
