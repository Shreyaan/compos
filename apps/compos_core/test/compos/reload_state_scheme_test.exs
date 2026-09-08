defmodule Compos.ReloadStateSchemeTest do
  @moduledoc """
  The two priv/tests/hot-reload-test.scm tests that guard persisted state.

  The whole suite runs them too, but a green suite prints nothing, so a
  test that never registered reads exactly like a test that passed. This
  names them.
  """

  use ExUnit.Case

  alias Compos.Core.Session

  @lane {:reload_state, __MODULE__}

  @names ~w(defvar-keeps-the-value-a-session-set every-persisted-global-uses-defvar)

  defp eval!(code) do
    {:ok, out} = Session.eval(code, nil, 60_000, @lane)
    out
  end

  @tag timeout: 180_000
  test "a reload cannot empty the state the desktop saves" do
    registered = eval!("(begin (load-tests-once!) (test-names))")

    for name <- @names do
      assert registered =~ name, "#{name} did not register"
      assert eval!("(run-test '#{name})") == "()", "#{name} failed"
    end
  end
end
