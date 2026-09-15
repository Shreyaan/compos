defmodule Compos.PromptSchemeTest do
  @moduledoc """
  Runs priv/tests/prompt-test.scm for prompt composition and snapshot lifecycle.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.Session

  @file_ Path.join([:code.priv_dir(:compos_core), "tests", "prompt-test.scm"])
  @lane {:scheme_suite, __MODULE__}

  defp eval!(code) do
    {:ok, out} = Session.eval(code, nil, 30_000, @lane)
    out
  end

  setup_all do
    eval!(~s{(load "#{@file_}")})
    :ok
  end

  for [_, name] <- Regex.scan(~r/\(deftest '([^\s()]+)/, File.read!(@file_)) do
    @tag prompt_snapshot:
           String.contains?(name, "snapshot-follows-a-rename") or
             name == "chat-thread-context-keeps-its-buffer-through-a-rename"
    test name do
      case Session.eval("(run-test '#{unquote(name)})", nil, 60_000, @lane) do
        {:ok, "()"} -> :ok
        {:ok, failures} -> flunk(failures)
        {:error, err} -> flunk("#{unquote(name)} raised: #{err}")
      end
    end
  end
end
