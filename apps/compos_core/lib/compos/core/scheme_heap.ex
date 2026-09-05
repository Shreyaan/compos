defmodule Compos.Core.SchemeHeap do
  @moduledoc """
  The heap bound for a process that evaluates Scheme.

  Emacs stops a runaway Lisp program with `max-lisp-eval-depth`. Here each
  Scheme execution runs on its own BEAM process, so the BEAM supplies the
  same guard: `max_heap_size` kills the process when its heap passes the
  bound. Without a bound, one loop that builds a list takes every byte the
  machine has and the whole editor swaps.

  The death of an evaluating process loses no state. The Scheme world lives
  in the shared ETS store and in the buffers, which is the same reason
  `Compos.Core.Lane.kill/1` is safe.

  Set `config :compos_core, scheme_heap_limit_mb: 0` to turn the bound off.
  """

  @default_mb 1024
  @word_bytes 8

  @doc "The configured bound in megabytes, or nil when it is off."
  def limit_mb do
    case Application.get_env(:compos_core, :scheme_heap_limit_mb, @default_mb) do
      mb when is_integer(mb) and mb > 0 -> mb
      _ -> nil
    end
  end

  @doc "The bound in words, or nil when it is off."
  def limit_words do
    case limit_mb() do
      nil -> nil
      mb -> div(mb * 1024 * 1024, @word_bytes)
    end
  end

  @doc "The `max_heap_size` options for `:erlang.spawn_opt/2`; empty when off."
  def spawn_opts do
    case limit_words() do
      nil -> []
      words -> [{:max_heap_size, flag(words)}]
    end
  end

  @doc "Put the bound on the calling process."
  def apply_to_self do
    case limit_words() do
      nil -> :ok
      words -> Process.flag(:max_heap_size, flag(words))
    end

    :ok
  end

  @doc "The error a caller reads when the bound stops its job."
  def exceeded_message(label) do
    name = if is_binary(label) and label != "", do: label, else: "the Scheme job"
    "#{name} passed the #{limit_mb()} MB heap limit and stopped"
  end

  defp flag(words), do: %{size: words, kill: true, error_logger: true}
end
