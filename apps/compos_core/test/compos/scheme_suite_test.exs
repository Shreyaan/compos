defmodule Compos.SchemeSuiteTest do
  @moduledoc """
  Runs the kernel's Scheme tests, priv/tests.

  Policy this editor decides in Scheme is tested in Scheme: the test calls
  the function and reads the value, with no keystroke in between. This
  module puts those tests in CI. A package's tests live beside the package
  and run in Compos.PackageSuiteTest, not here. A new file in priv/tests
  needs no change here.

      SCHEME_TESTS=keymap mix test test/compos/scheme_suite_test.exs
  """

  use ExUnit.Case

  alias Compos.SchemeSuite

  # Before trusting a green suite, prove the harness can go red. Three bad
  # assertions must record, one good one must not. Without this a broken
  # check- function reads exactly like a passing suite.
  test "the harness can fail" do
    out = SchemeSuite.eval!("(test-self-check)")

    assert out =~ "canary-must-fail", "check-equal! recorded no failure"
    assert out =~ "canary-true-must-fail", "check-true! recorded no failure"
    assert out =~ "canary-false-must-fail", "check-false! recorded no failure"
    refute out =~ "canary-must-pass", "a passing check recorded a failure"
  end

  # priv/tests/canary-test.scm registers this, and it fails on purpose.
  @canary "zz-canary-always-fails"

  # test-self-check calls the check functions directly. This goes the whole
  # way: a file loads, a test registers, run-test runs it, and a failure
  # comes back. A file that fails to load takes its tests with it in
  # silence, and without this the bridge reads that as a shorter green run.
  test "a registered test can load, run, and report red" do
    found = SchemeSuite.names(:core)

    assert @canary in found,
           "the canary did not load — priv/tests is not being read, or a file raised on load"

    assert {:ok, out} = SchemeSuite.eval("(run-test '#{@canary})")
    assert out =~ "canary", "the canary ran and reported nothing: run-test cannot go red"
    refute out == "()", "the canary passed, so a failing test reports as passing"
  end

  # Test files share one namespace: a helper defined in two files silently
  # takes the definition of whichever loaded last. Two morg files both
  # defined t--morg! with different arities, and five tests died with
  # "arity mismatch" pointing at neither file. A live editor can load both
  # suites, so the check spans the kernel files and the package files.
  test "no two test files define the same helper" do
    clashes = SchemeSuite.clashes([:core, :packages])
    assert clashes == [], "defined in more than one test file: #{inspect(clashes)}"
  end

  # Some files reset buffer names the editor itself owns — notmuch's
  # *notmuch* and *mail*. They declare it, and run-scheme-tests skips them
  # in a live editor. Here the home is a throwaway one, so they MUST run:
  # a gate that quietly hid them would be worse than no gate.
  test "the gated tests are not gated here" do
    assert SchemeSuite.eval!("(begin (load-tests-once!) (editor-is-disposable?))") == "#t",
           "the test home is not disposable, so the suite would skip the gated files"

    assert SchemeSuite.eval!("(length (test-names-here))") == SchemeSuite.eval!("(length (test-names))"),
           "the suite is skipping tests it should be running"
  end

  # A file that raises on load takes its tests with it in silence, and a
  # green run then reads like a pass. Every file on disk must register
  # every test it declares.
  test "every test file registered every test it declares" do
    missing = SchemeSuite.missing(:core, SchemeSuite.names(:core))
    assert missing == [], "declared but not registered:\n" <> Enum.join(missing, "\n")
  end

  # The whole kernel suite runs inside this one test.
  @tag timeout: 180_000
  test "the Scheme suite passes" do
    found = SchemeSuite.names(:core)
    assert found != [], "priv/tests registered no tests — did load-tests! find the directory?"

    real = found |> SchemeSuite.own(:core) |> SchemeSuite.selected(:core) |> Kernel.--([@canary])
    assert real != [], "no test matched SCHEME_TESTS=#{System.get_env("SCHEME_TESTS")}"

    failures = SchemeSuite.run(real)
    assert failures == [], "\n" <> Enum.join(failures, "\n")
  end
end
