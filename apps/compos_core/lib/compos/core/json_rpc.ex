defmodule Compos.Core.JsonRpc do
  @moduledoc """
  Line-framed JSON-RPC over a byte stream, the way ACP, the Codex app
  server and an MCP server over stdio speak it. This module holds the
  framing and the envelopes. Each speaker keeps its own vocabulary and
  the ids it has in flight.
  """

  @doc "The complete lines in BUF and the unconsumed tail. Blank lines are dropped."
  def split_lines(buf) do
    {lines, [rest]} = buf |> String.split("\n") |> Enum.split(-1)
    {Enum.reject(lines, &(String.trim(&1) == "")), rest}
  end

  @doc "Every complete JSON frame in BUF and the tail. A line that is not JSON is chatter on stdout and is dropped."
  def decode_lines(buf) do
    {lines, rest} = split_lines(buf)

    frames =
      Enum.flat_map(lines, fn line ->
        case Jason.decode(line) do
          {:ok, frame} -> [frame]
          {:error, _} -> []
        end
      end)

    {frames, rest}
  end

  @doc "One frame as wire bytes: the JSON and a newline."
  def encode(frame), do: [Jason.encode!(frame), "\n"]

  @doc "A request envelope. `header: false` leaves the jsonrpc member out, as the Codex app server wants."
  def request(id, method, params, opts \\ []),
    do: envelope(%{"id" => id, "method" => method, "params" => params}, opts)

  @doc "A notification envelope."
  def notification(method, params, opts \\ []),
    do: envelope(%{"method" => method, "params" => params}, opts)

  @doc "A result envelope for the request ID."
  def response(id, result, opts \\ []), do: envelope(%{"id" => id, "result" => result}, opts)

  @doc "An error envelope for the request ID."
  def error(id, code, message, opts \\ []),
    do: envelope(%{"id" => id, "error" => %{"code" => code, "message" => message}}, opts)

  defp envelope(frame, opts) do
    if Keyword.get(opts, :header, true), do: Map.put(frame, "jsonrpc", "2.0"), else: frame
  end
end
