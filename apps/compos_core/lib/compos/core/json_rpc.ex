defmodule Compos.Core.JsonRpc do
  @moduledoc """
  JSON-RPC over a byte stream: lines for ACP, the Codex app server, an
  MCP server over stdio, the compos socket and a peer daemon, and
  Content-Length frames for LSP. This module holds the framing and the
  envelopes. Each speaker keeps its own vocabulary and
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

  @doc "One frame as LSP wire bytes: a Content-Length header, a blank line, the JSON."
  def encode_content_length(frame) do
    json = Jason.encode!(frame)
    ["Content-Length: ", Integer.to_string(byte_size(json)), "\r\n\r\n", json]
  end

  @doc """
  Every complete Content-Length frame in BUF, decoded, and the tail. The
  LSP base protocol; a bare `\\n\\n` after the header is tolerated, and a
  frame that is not JSON is dropped.
  """
  def split_content_length(buf, acc \\ []) do
    case header_split(buf) do
      nil ->
        {Enum.reverse(acc), buf}

      {header, rest} ->
        case content_length(header) do
          nil ->
            split_content_length(rest, acc)

          len when byte_size(rest) >= len ->
            body = binary_part(rest, 0, len)
            tail = binary_part(rest, len, byte_size(rest) - len)

            case Jason.decode(body) do
              {:ok, msg} -> split_content_length(tail, [msg | acc])
              _ -> split_content_length(tail, acc)
            end

          _ ->
            {Enum.reverse(acc), buf}
        end
    end
  end

  defp header_split(buf) do
    crlf = :binary.match(buf, "\r\n\r\n")
    lf = :binary.match(buf, "\n\n")

    case first_match(crlf, lf) do
      nil ->
        nil

      {pos, len} ->
        {binary_part(buf, 0, pos), binary_part(buf, pos + len, byte_size(buf) - pos - len)}
    end
  end

  defp first_match(:nomatch, :nomatch), do: nil
  defp first_match({p, l}, :nomatch), do: {p, l}
  defp first_match(:nomatch, {p, l}), do: {p, l}
  defp first_match({p1, l1}, {p2, _}) when p1 <= p2, do: {p1, l1}
  defp first_match(_, {p2, l2}), do: {p2, l2}

  defp content_length(header) do
    header
    |> String.split(~r/\r?\n/)
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [k, v] ->
          if String.downcase(String.trim(k)) == "content-length" do
            case Integer.parse(String.trim(v)) do
              {n, _} -> n
              _ -> nil
            end
          end

        _ ->
          nil
      end
    end)
  end

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
