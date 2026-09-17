defmodule Compos.AdviceTest do
  use ExUnit.Case
  alias Compos.Core.Session

  @suite_file Path.join([:code.priv_dir(:compos_core), "tests", "advice-test.scm"])
  @package Path.join(Compos.Core.project_dir(), "scheme/packages/advice.scm")
  @lane {:scheme_suite, __MODULE__}

  setup do
    # The normal boot manifest supplies the API; the test loads only fixtures.
    assert {:ok, "#t"} = Session.eval("(procedure? advice-add!)")
    assert {:ok, _} = Session.eval(~s|(load "#{@suite_file}")|, nil, 30_000, @lane)
    on_exit(fn -> Session.eval("(advice-test-reset!)", nil, 30_000, @lane) end)
    :ok
  end

  test "source reload preserves disabled advice and replaces the original" do
    path = Path.join(System.tmp_dir!(), "advice-reload-#{System.unique_integer([:positive])}.scm")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, "(define (advice-test-reloaded x) (+ x 1))")
    assert {:ok, _} = Session.eval(~s|(load "#{path}")|)

    assert {:ok, _} =
             Session.eval("""
             (advice-add! 'advice-test-reloaded 'after 'log 'advice-test-after)
             (advice-disable! 'advice-test-reloaded 'log)
             """)

    File.write!(path, "(define (advice-test-reloaded x) (+ x 10))")
    Session.reload_files([path])
    assert {:ok, "11"} = Session.eval("(advice-test-reloaded 1)")
    assert {:ok, "#f"} = Session.eval("(advice-enabled? 'advice-test-reloaded 'log)")
    # A complete package load must also retain registry state.
    assert {:ok, _} = Session.eval(~s|(load "#{@package}")|)
    assert {:ok, "#f"} = Session.eval("(advice-enabled? 'advice-test-reloaded 'log)")

    assert {:ok, "((after 1))"} =
             Session.eval("""
             (set! *advice-test-log* '())
             (advice-enable! 'advice-test-reloaded 'log)
             (advice-test-reloaded 1)
             *advice-test-log*
             """)

    assert {:ok, "11"} =
             Session.eval("""
             (advice-remove! 'advice-test-reloaded 'log)
             (advice-test-reloaded 1)
             """)
  end
end
