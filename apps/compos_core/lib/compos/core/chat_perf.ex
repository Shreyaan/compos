defmodule Compos.Core.ChatPerf do
  @moduledoc "Writes one append-only performance trace for each chat session."

  @dir "chat-perf"

  def path(slug) do
    Path.join([Compos.Core.home(), @dir, safe_slug(slug) <> ".chat-perf.jsonl"])
  end

  def emit(slug, kind, attrs \\ %{}) when is_binary(slug) do
    event =
      attrs
      |> stringify_keys()
      |> Map.merge(%{
        "at_us" => System.system_time(:microsecond),
        "mono_us" => System.monotonic_time(:microsecond),
        "kind" => to_string(kind),
        "chat" => slug
      })

    line = Jason.encode_to_iodata!(event, escape: :json) |> then(&[&1, ?\n])
    file = path(slug)

    Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, line, [:append])
    end)

    :ok
  end

  def events(slug) do
    case File.read(path(slug)) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, event} -> [event]
            _ -> []
          end
        end)

      {:error, :enoent} ->
        []

      {:error, _} ->
        []
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), json_value(value)} end)
  end

  defp json_value(value) when is_atom(value), do: to_string(value)
  defp json_value(value) when is_pid(value), do: inspect(value)
  defp json_value(value), do: value

  defp safe_slug(slug), do: String.replace(slug, ~r/[^A-Za-z0-9_.-]/, "_")
end
