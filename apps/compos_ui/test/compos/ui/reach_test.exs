defmodule Compos.Ui.ReachTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Compos.Ui.Reach

  defp from(ip) do
    conn(:get, "/") |> Map.put(:remote_ip, ip) |> Reach.call([])
  end

  test "loopback and tailnet addresses pass; the LAN and the internet get 403" do
    refute from({127, 0, 0, 1}).halted
    refute from({0, 0, 0, 0, 0, 0, 0, 1}).halted
    refute from({100, 93, 101, 79}).halted
    refute from({0xFD7A, 0x115C, 0xA1E0, 0, 0, 0x4E01, 0x654F, 1}).halted
    refute from({0, 0, 0, 0, 0, 0xFFFF, 100 * 256 + 93, 101 * 256 + 79}).halted

    assert from({192, 168, 1, 20}).halted
    assert from({192, 168, 1, 20}).status == 403
    assert from({100, 20, 0, 1}).halted
    assert from({8, 8, 8, 8}).halted
  end

  test "an origin is local when it names loopback, this host, or a tailnet address" do
    {:ok, raw} = :inet.gethostname()
    name = raw |> to_string() |> String.split(".") |> hd() |> String.downcase()

    assert Reach.local_origin?(URI.parse("http://localhost:4004"))
    assert Reach.local_origin?(URI.parse("http://127.0.0.1:4004"))
    assert Reach.local_origin?(URI.parse("http://#{name}:4004"))
    assert Reach.local_origin?(URI.parse("http://#{name}.tail1cc8f.ts.net:4004"))
    assert Reach.local_origin?(URI.parse("http://100.93.101.79:4004"))

    refute Reach.local_origin?(URI.parse("http://other.tail1cc8f.ts.net:4004"))
    refute Reach.local_origin?(URI.parse("http://192.168.1.20:4004"))
    refute Reach.local_origin?(URI.parse("https://evil.example"))
    refute Reach.local_origin?(nil)
  end
end
