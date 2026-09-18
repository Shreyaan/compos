defmodule Compos.PackageSuiteTest do
  @moduledoc """
  Runs the Scheme tests that live beside the packages, as in Emacs:
  scheme/packages/NAME-test.scm, or NAME-test.scm inside a package's own
  directory. The kernel's run does not include them. Run them apart:

      mix test --include packages test/compos/package_suite_test.exs
      SCHEME_TESTS=morg mix test --include packages test/compos/package_suite_test.exs
  """

  use ExUnit.Case

  alias Compos.SchemeSuite

  @moduletag :packages

  test "every package test file registered every test it declares" do
    missing = SchemeSuite.missing(:packages, SchemeSuite.names(:packages))
    assert missing == [], "declared but not registered:\n" <> Enum.join(missing, "\n")
  end

  @tag timeout: 600_000
  test "the package tests pass" do
    found = SchemeSuite.names(:packages)
    real = found |> SchemeSuite.own(:packages) |> SchemeSuite.selected(:packages)
    assert real != [], "no package test matched SCHEME_TESTS=#{System.get_env("SCHEME_TESTS")}"

    failures = SchemeSuite.run(real)
    assert failures == [], "\n" <> Enum.join(failures, "\n")
  end
end
