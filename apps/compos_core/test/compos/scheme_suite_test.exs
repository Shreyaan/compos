defmodule Compos.SchemeSuiteTest do
  @moduledoc """
  Runs the Scheme test suite in priv/tests.

  Policy this editor decides in Scheme is tested in Scheme: the test calls
  the function and reads the value, with no keystroke in between. This
  module is the bridge that puts those tests in CI.

  One eval per test, so a test that raises fails alone and the rest still
  run. A new file in priv/tests needs no change here.
  """

  use ExUnit.Case

  alias Compos.Core.Session

  # The suite runs on its OWN lane, never :ui.
  #
  # wait-until holds the lane it runs on, and the editor delivers its
  # work on :ui — an on-change hook, an LSP status, a debounced redraw.
  # A suite that holds :ui blocks the very deliveries its tests wait for,
  # and they time out looking exactly like a slow server. Off :ui they
  # land in milliseconds.
  @lane {:scheme_suite, __MODULE__}

  defp eval!(code) do
    {:ok, out} = eval(code)
    out
  end

  # a test that hangs is that test's failure, and the tests after it still run
  defp eval(code) do
    Session.eval(code, nil, 30_000, @lane)
  catch
    :exit, reason -> {:error, "timed out: #{inspect(reason, limit: 3)}"}
  end

  # symbols print as a bare list: (a b c)
  defp names do
    eval!("(begin (load-tests-once!) (test-names))")
    |> String.trim_leading("(")
    |> String.trim_trailing(")")
    |> String.split(" ", trim: true)
  end

  @tests_dir Path.join(:code.priv_dir(:compos_core), "tests")

  # the deftest names a file declares, read from the file
  defp declared(path) do
    Regex.scan(~r/\(deftest '([^\s()]+)/, File.read!(path))
    |> Enum.map(fn [_, name] -> name end)
  end

  # One file at a time, for work on that file:
  #   SCHEME_TESTS=morg mix test test/compos/scheme_suite_test.exs
  # matches every priv/tests file whose name contains the word; a comma
  # separates several words.
  defp selected(names) do
    case System.get_env("SCHEME_TESTS") do
      nil ->
        names

      words ->
        wanted =
          for word <- String.split(words, ","),
              path <- Path.wildcard(Path.join(@tests_dir, "*#{String.trim(word)}*.scm")),
              name <- declared(path),
              do: name

        Enum.filter(names, &(&1 in wanted))
    end
  end

  # Before trusting a green suite, prove the harness can go red. Three bad
  # assertions must record, one good one must not. Without this a broken
  # check- function reads exactly like a passing suite.
  test "the harness can fail" do
    out = eval!("(test-self-check)")

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
    found = names()

    assert @canary in found,
           "the canary did not load — priv/tests is not being read, or a file raised on load"

    assert {:ok, out} = eval("(run-test '#{@canary})")
    assert out =~ "canary", "the canary ran and reported nothing: run-test cannot go red"
    refute out == "()", "the canary passed, so a failing test reports as passing"
  end

  # Test files share one namespace: load-tests! loads them in directory
  # order, so a helper defined in two files silently takes the definition
  # of whichever loaded last. Two morg files both defined t--morg! with
  # different arities, and five tests died with "arity mismatch" pointing
  # at neither file. Names are checked here because it is a fact about the
  # files on disk, not about any one test.
  test "no two test files define the same helper" do
    dir = Path.join(:code.priv_dir(:compos_core), "tests")

    owners =
      for path <- Path.wildcard(Path.join(dir, "*.scm")),
          [_, name] <- Regex.scan(~r/^\(define \(([^\s)]+)/m, File.read!(path)),
          reduce: %{} do
        acc -> Map.update(acc, name, [Path.basename(path)], &[Path.basename(path) | &1])
      end

    clashes = for {name, files} <- owners, length(Enum.uniq(files)) > 1, do: {name, files}

    assert clashes == [], "defined in more than one test file: #{inspect(clashes)}"
  end

  # Some files reset buffer names the editor itself owns — notmuch's
  # *notmuch* and *mail*. They declare it, and run-scheme-tests skips them
  # in a live editor. Here the home is a throwaway one, so they MUST run:
  # a gate that quietly hid them would be worse than no gate.
  test "the gated tests are not gated here" do
    assert eval!("(begin (load-tests-once!) (editor-is-disposable?))") == "#t",
           "the test home is not disposable, so the suite would skip the gated files"

    gated = eval!("(length *disposable-only-tests*)") |> String.to_integer()
    assert gated > 0, "no file declares itself disposable-only — did the declaration move?"

    assert eval!("(length (test-names-here))") == eval!("(length (test-names))"),
           "the suite is skipping #{gated} tests it should be running"
  end

  # A file that raises on load takes its tests with it in silence, and a
  # green run then reads like a pass. Every file on disk must register
  # every test it declares.
  test "every test file registered every test it declares" do
    found = names()

    missing =
      for path <- Path.wildcard(Path.join(@tests_dir, "*.scm")),
          name <- declared(path),
          name not in found,
          do: "#{Path.basename(path)}: #{name}"

    assert missing == [], "declared but not registered:\n" <> Enum.join(missing, "\n")
  end

  # The whole Scheme suite runs inside this one test, and it has grown
  # past the 60s ExUnit default.
  @tag timeout: 180_000
  test "the Scheme suite passes" do
    found = names()

    assert found != [], "priv/tests registered no tests — did load-tests! find the directory?"

    real = selected(found -- [@canary])

    assert real != [], "no test matched SCHEME_TESTS=#{System.get_env("SCHEME_TESTS")}"

    {failures, times} =
      Enum.reduce(real, {[], []}, fn name, {fails, times} ->
        {us, result} = :timer.tc(fn -> eval("(run-test '#{name})") end)
        reduced = reduce(name, result)
        {if(reduced, do: [reduced | fails], else: fails), [{div(us, 1000), name} | times]}
      end)

    # SCHEME_TIMES=1 prints the slowest tests, for work on the editor's cost
    if System.get_env("SCHEME_TIMES") do
      times
      |> Enum.sort(:desc)
      |> Enum.take(25)
      |> Enum.each(fn {ms, name} -> IO.puts("  #{String.pad_leading(to_string(ms), 6)}ms  #{name}") end)
    end

    assert failures == [], "\n" <> Enum.join(Enum.reverse(failures), "\n")
  end

  # "()" is a pass. Anything else is the test's own report, or the eval
  # died — which is a failure of that test and not of this one.
  defp reduce(_name, {:ok, "()"}), do: nil
  defp reduce(name, {:ok, out}), do: "  #{name}\n      #{out}"
  defp reduce(name, {:error, msg}), do: "  #{name}\n      raised: #{msg}"
end
