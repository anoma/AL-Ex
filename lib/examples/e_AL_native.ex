defmodule Examples.ALNative.Divisors do
  @moduledoc """
  A :raw-style native -- the full `(call_args, state) :: AL.t() | nil`
  contract, used here to prove natives may be nondeterministic via AL's
  existing `fan_out` choicepoint mechanism (no new engine work needed).
  """

  def divisors([n, divisor], state) do
    store = state.active_choicepoint.store
    n_value = AL.Var.deref(store, n)

    if AL.Var.var?(n_value) do
      AL.backtrack(state)
    else
      divisors = for d <- 1..n_value, rem(n_value, d) == 0, do: d
      AL.fan_out(state, divisors, fn d -> {AL.unify(state, divisor, d), [divisor]} end)
    end
  end
end

defmodule Examples.ALNative do
  @moduledoc """
  Native (Elixir-backed) methods: registering genuinely new capability
  under an AL selector with no AL-level spec required, and the
  durable-binding/ephemeral-implementation split that makes a missing
  implementation a loud, specific diagnostic instead of a silent DNU.

  Each example targets its own selector name to stay independent, and
  retracts what it registered when done -- AL.Native.Registry is node-wide,
  not reset between examples the way the :examples branch's own data is.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  @examples_branch %AL.Branch{id: :examples}

  example native_method_runs_and_produces_a_result() do
    {:ok, method_id} =
      AL.Native.register(:number, :al_native_gcd, Integer, :gcd, 2, branch: @examples_branch)

    {:atomic, {bindings, _}} =
      run branch: :examples do
        al_native_gcd(12, 8, result)
      end

    assert Map.get(bindings, :"$result") == 4

    AL.Native.retract(method_id, branch: @examples_branch)
    :ok
  end

  # Simulates an image restart: the durable fact survives (AL.Object's
  # :native soa row), the ephemeral implementation doesn't
  # (AL.Native.Registry is node-wide, not durable) -- the call must fail
  # loud and specific, never a plain "no matching clause"/DNU.
  example missing_native_implementation_is_a_named_diagnostic() do
    {:ok, method_id} =
      AL.Native.register(:number, :al_native_missing_demo, Integer, :gcd, 2,
        branch: @examples_branch
      )

    AL.Native.Registry.delete(method_id)

    {:aborted, reason} =
      run branch: :examples do
        al_native_missing_demo(12, 8, result)
      end

    assert match?({:native_missing, ^method_id, {Integer, :gcd, 2}}, reason.reason)
    assert reason.message =~ "declared native"
    assert reason.message =~ "not registered in this image"

    AL.Native.retract(method_id, branch: @examples_branch)
    :ok
  end

  # register/6 called again with the exact same binding (as automatic
  # boot-time re-registration does, see AL.Application.register_natives/0)
  # must not raise, and must restore the ephemeral implementation.
  example re_registering_the_same_binding_is_idempotent() do
    {:ok, method_id} =
      AL.Native.register(:number, :al_native_idempotent, Integer, :gcd, 2,
        branch: @examples_branch
      )

    {:ok, ^method_id} =
      AL.Native.register(:number, :al_native_idempotent, Integer, :gcd, 2,
        branch: @examples_branch
      )

    {:atomic, {bindings, _}} =
      run branch: :examples do
        al_native_idempotent(9, 6, result)
      end

    assert Map.get(bindings, :"$result") == 3

    AL.Native.retract(method_id, branch: @examples_branch)
    :ok
  end

  example conflicting_registration_is_rejected() do
    {:ok, method_id} =
      AL.Native.register(:number, :al_native_conflict, Integer, :gcd, 2, branch: @examples_branch)

    assert_raise RuntimeError, ~r/refusing to register/, fn ->
      AL.Native.register(:number, :al_native_conflict, Kernel, :max, 2, branch: @examples_branch)
    end

    AL.Native.retract(method_id, branch: @examples_branch)
    :ok
  end

  # Registering a native over a method_id that already has real interpreted
  # oapply clauses (:number#factorial, from bootstrap) is functionally what
  # a jet would do -- out of scope, rejected unless force: true.
  example native_over_existing_interpreted_clauses_is_rejected_without_force() do
    assert_raise RuntimeError, ~r/already has real interpreted clauses/, fn ->
      AL.Native.register(:number, :factorial, Integer, :gcd, 2, branch: @examples_branch)
    end

    :ok
  end

  example nondet_raw_native_produces_multiple_solutions_via_fan_out() do
    {:ok, method_id} =
      AL.Native.register(
        :number,
        :al_native_divisors,
        Examples.ALNative.Divisors,
        :divisors,
        2,
        style: :raw,
        branch: @examples_branch
      )

    {:atomic, {bindings, _}} =
      run branch: :examples do
        findall(d, [al_native_divisors(6, d)], all)
      end

    assert Enum.sort(Map.get(bindings, :"$all")) == [1, 2, 3, 6]

    AL.Native.retract(method_id, branch: @examples_branch)
    :ok
  end
end
