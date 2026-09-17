defmodule Compos.Test.FakeTransport do
  @moduledoc """
  The ACP test seam. A test puts its pid under `:fake_transport_pid`;
  `open` answers `{:transport_open, owner}` and `{:transport_cmd, cmd}`,
  every frame the Agent sends arrives as `{:frame, decoded_map}`, and the
  test injects adapter output with `send(agent, {:acp_data, json <> "\\n"})`.
  """

  @behaviour Compos.Core.Agent.Transport

  @doc "Register the calling test as the transport's owner."
  def own!, do: :persistent_term.put(:fake_transport_pid, self())

  @impl true
  def open(cmd, _opts, owner) do
    test = :persistent_term.get(:fake_transport_pid)
    send(test, {:transport_open, owner})
    send(test, {:transport_cmd, cmd})
    {:ok, test}
  end

  @impl true
  def send_frame(test, data) do
    send(test, {:frame, Jason.decode!(IO.iodata_to_binary(data))})
    :ok
  end

  @impl true
  def close(_test), do: :ok
end
