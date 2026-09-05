defmodule Compos.InterposeTest do
  use ExUnit.Case, async: true
  alias Compos.Scheme
  alias Compos.Scheme.{Env, Printer}

  defp evaluate(interp, source) do
    assert {:ok, value, interp} = Scheme.eval_string(interp, source)
    {value, interp}
  end

  defp wrap(interp, target, source) do
    {wrapper, interp} = evaluate(interp, source)
    %{interp | store: Env.interpose(interp.store, interp.global, target, wrapper)}
  end

  for shared <- [false, true] do
    test "binding replacement preserves the wrapper, shared=#{shared}" do
      {_, interp} = evaluate(Scheme.new(), "(define (f x) (+ x 1))")
      interp = if unquote(shared), do: Scheme.flush(interp), else: interp
      interp = wrap(interp, "f", "(lambda (original args) (* 2 (apply original args)))")
      {value, interp} = evaluate(interp, "(f 3)")
      assert value == 8
      {value, interp} = evaluate(interp, "(define (f x) (+ x 2)) (apply f '(3))")
      assert value == 10
      {value, interp} = evaluate(interp, "(set! f (lambda (x) (+ x 3))) (f 3)")
      assert value == 12
      {value, interp} = evaluate(interp, "(let () (define (f x) x) (f 3))")
      assert value == 3
      {value, interp} = evaluate(interp, "(procedure? f)")
      assert value
      {source, interp} = evaluate(interp, "(function-source f)")
      assert source == "(lambda (x) (+ x 3))"
      {function, interp} = evaluate(interp, "f")
      assert Printer.print(function) =~ "interposed"
      interp = %{interp | store: Env.interpose(interp.store, interp.global, "f", false)}
      {value, _} = evaluate(interp, "(f 3)")
      assert value == 6
    end
  end

  test "wrapper replacement does not stack and invalid registration leaves the binding alone" do
    {_, interp} = evaluate(Scheme.new(), "(define (f x) x)")
    interp = wrap(interp, "f", "(lambda (original args) (+ 1 (apply original args)))")
    interp = wrap(interp, "f", "(lambda (original args) (+ 10 (apply original args)))")
    {value, interp} = evaluate(interp, "(f 2)")
    assert value == 12
    assert_raise ArgumentError, fn -> Env.interpose(interp.store, interp.global, "f", 42) end
    {value, _} = evaluate(interp, "(f 2)")
    assert value == 12
  end

  test "captured wrapper and original survive publication, collection, and actor snapshots" do
    {_, interp} = evaluate(Scheme.new(), "(define f (let ((n 3)) (lambda (x) (+ n x))))")

    interp =
      wrap(
        interp,
        "f",
        "(let ((factor 2)) (lambda (original args) (* factor (apply original args))))"
      )

    interp = Scheme.flush(interp)
    interp = Scheme.gc(interp, [])
    {value, interp} = evaluate(interp, "(f 4)")
    assert value == 14
    actor = interp |> Scheme.snapshot() |> Scheme.from_snapshot()
    {value, _} = evaluate(actor, "(f 4)")
    assert value == 14
  end

  test "primitive refresh replaces the original without losing or nesting its wrapper" do
    interp = Scheme.new(primitives: %{"host" => fn [n] -> n + 1 end})
    interp = wrap(interp, "host", "(lambda (original args) (* 2 (apply original args)))")
    interp = Scheme.flush(interp)
    interp = Scheme.rebind_primitives(interp, %{"host" => fn [n] -> n + 5 end})
    {value, interp} = evaluate(interp, "(host 1)")
    assert value == 12
    interp = %{interp | store: Env.interpose(interp.store, interp.global, "host", false)}
    {value, _} = evaluate(interp, "(host 1)")
    assert value == 6
  end
end
