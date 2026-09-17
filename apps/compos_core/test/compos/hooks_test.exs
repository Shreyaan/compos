defmodule Compos.HooksTest do
  @moduledoc """
  The one hook the Elixir side must run: post-command-hook after self-insert.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Editor, KeyDispatch, Session}

  @lane {:scheme_suite, __MODULE__}

  defp eval!(code) do
    {:ok, out} = Session.eval(code, nil, 30_000, @lane)
    out
  end

  test "post-command-hook runs after self-insert" do
    name = "*hook-self-insert-#{System.unique_integer([:positive])}*"
    {:ok, ^name} = Compos.Core.create_buffer(name)
    Editor.minibuffer_close()
    Editor.set_window_buffer(name)

    eval!("(define *hook-test-typed* 0)")
    eval!("(define (hook-test-count!) (set! *hook-test-typed* (+ *hook-test-typed* 1)))")
    eval!("(add-hook! 'post-command-hook 'hook-test-count!)")

    try do
      KeyDispatch.handle_key("a")
      assert eval!("*hook-test-typed*") == "1"
    after
      eval!("(remove-hook! 'post-command-hook 'hook-test-count!)")
      Compos.Core.kill_buffer(name)
    end
  end
end
