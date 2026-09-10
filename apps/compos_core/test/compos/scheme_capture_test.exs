defmodule Compos.SchemeCaptureTest do
  @moduledoc """
  No Scheme file captures a function with a bare `define` before it shadows
  the same name.

  The editor wraps a function by capturing it under a second name, then
  defining a wrapper under the first name. A whole-file reload evaluates
  both forms again, and the capture then reads the WRAPPER. The wrapper
  calls itself, and the next call recurses until the heap bound kills the
  job. On 2026-09-10 `define-command--raw` took that path in a daemon that
  had run for weeks, and no command could be defined again.

  `alias-once!` keeps the first capture, so this test names the shape rather
  than the 22 places that used it: a capture stays safe when somebody adds
  the twenty-third.

  The check reads each file with the Scheme reader and stays inside one
  file, which is where every capture in the tree wraps its target.
  """

  use ExUnit.Case, async: true

  alias Compos.Scheme.Reader

  defp scheme_files do
    priv = Application.app_dir(:compos_core, "priv")

    Path.wildcard(Path.join(priv, "*.scm")) ++
      Path.wildcard(Path.join([priv, "packages", "**/*.scm"]))
  end

  # (define NAME TARGET) — a bare alias of one name to another
  defp capture({[{:sym, "define"}, {:sym, name}, {:sym, target}], index}),
    do: {name, target, index}

  defp capture(_), do: nil

  # (define (TARGET ...) ...) — TARGET becomes a function of this file's own
  defp shadow({[{:sym, "define"}, [{:sym, target} | _] | _], index}), do: {target, index}
  defp shadow(_), do: nil

  defp offenders(path) do
    forms = path |> File.read!() |> Reader.read_all() |> Enum.with_index()

    captures = forms |> Enum.map(&capture/1) |> Enum.reject(&is_nil/1)
    shadows = forms |> Enum.map(&shadow/1) |> Enum.reject(&is_nil/1) |> Map.new()

    for {name, target, at} <- captures,
        shadowed_at = shadows[target],
        shadowed_at > at,
        do: "#{Path.basename(path)}: (define #{name} #{target}) captures #{target}, " <>
              "which the same file shadows below — use (alias-once! '#{name} '#{target})"
  end

  test "a capture before a shadow uses alias-once!" do
    found = Enum.flat_map(scheme_files(), &offenders/1)
    assert found == [], Enum.join(found, "\n")
  end
end
