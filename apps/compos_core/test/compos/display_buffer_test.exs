defmodule Compos.DisplayBufferTest do
  @moduledoc "The Scheme display-buffer tests, in this daemon: they rearrange windows, so never in the live one."
  use ExUnit.Case

  alias Compos.Core.{Editor, Session}

  setup do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)

    on_exit(fn ->
      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end)

    %{frame: frame}
  end

  @file_ Path.join([:code.priv_dir(:compos_core), "tests", "display-buffer-test.scm"])
  # Window commands and their configuration hooks share the GUI lane.
  @lane :ui

  defp names do
    Regex.scan(~r/\(deftest '([^\s()]+)/, File.read!(@file_))
    |> Enum.map(fn [_, name] -> name end)
  end

  @tag timeout: 120_000
  test "display-buffer-test.scm passes", %{frame: frame} do
    {:ok, _} = Session.eval(~s{(load "#{@file_}")}, frame, 30_000, @lane)
    names = names()
    assert names != [], "the file declares no test"

    for name <- names do
      case Session.eval("(run-test '#{name})", frame, 60_000, @lane) do
        {:ok, "()"} -> :ok
        {:ok, failures} -> flunk("#{name} failed: #{failures}")
        {:error, err} -> flunk("#{name} raised: #{err}")
      end
    end
  end
end
