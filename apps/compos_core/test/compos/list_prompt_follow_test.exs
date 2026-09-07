defmodule Compos.ListPromptFollowTest do
  @moduledoc """
  A list moved from its prompt keeps its row on screen: every window
  showing the list takes the row's point and drops its scroll pin.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Editor, Session}

  defp eval!(code) do
    {:ok, out} = Session.eval(code, nil, 30_000)
    out
  end

  defp leaf(tree, name) do
    Regex.run(~r/\{:leaf, "#{Regex.escape(name)}", \d+, (\d+), (true|false), (\d+)/, tree)
  end

  test "moving a list under its prompt sets the window's point and drops its scroll pin" do
    eval!(~s{(begin
      (for-each (lambda (n) (buffer-create (string-append "*zz-lpf-" (number->string n) "*")))
                (list 1 2 3 4 5))
      (switch-to-buffer! "*zz-lpf-1*"))})

    eval!(~s{(run-command "ibuffer-prompt")})
    assert eval!("(popup-open?)") == "#t"
    win = eval!("(popup-window)") |> String.to_integer()

    # the client's own follow scroll reports back: the window is pinned
    Editor.set_client_top(win, 300)
    assert [_, _, "true", "300"] = leaf(eval!("(window-tree)"), " *buffers*")

    before = eval!(~s{(window-point #{win})})
    eval!(~s{(run-command "minibuffer-next-candidate")})

    assert [_, point, "false", "0"] = leaf(eval!("(window-tree)"), " *buffers*")
    assert point != before
    assert eval!(~s{(window-point #{win})}) == eval!(~s{(buffer-point " *buffers*")})

    eval!("(minibuffer-cancel!)")
    eval!(~s{(for-each (lambda (n) (buffer-kill! (string-append "*zz-lpf-" (number->string n) "*"))) (list 1 2 3 4 5))})
  end
end
