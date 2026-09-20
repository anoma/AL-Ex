Code.require_file("support.exs", __DIR__)

defmodule Bench.Regsm do
  @moduledoc """
      mix run bench/regsm.exs <variant> <n> <p>
      mix run bench/regsm.exs <variant> <from> <to> <step> <p>
      mix run bench/regsm.exs repeat <variant> <n> <p> <k>

  I time fibonacci mod `p` written as a register recurrence -- `A = (A' + B')
  - Q*p`, `B = A'`, base `regsm(1, 1, 1, 0)`, first argument ground and
  counting down.

  `regsm_entry` posts every constraint (the mod equation, the range guards,
  the `b = a1` aliasing) at clause entry, before the recursive call that will
  ground it, the way zkfol's AL emission does. `regsm_body` posts the equation
  and the guards after the call instead.

  Both orders are linear, at about three times the per-frame cost for the
  entry order, which posts four propagators a frame over vars that are all
  still open. Before the wake split (`AL.Var.Bounds`) the entry order was
  not linear at all: bounds consistency between two sides that are both
  still open converges one unit per round, so past a data-dependent onset
  (n ~ 7930 at p = 7919, n ~ 1800 at p = 7883) each further frame cost O(p)
  narrowings -- 20s at n = 8000, 273s at n = 10000, 162s at n = 4000 with
  p = 7883.

  `repeat` runs k solves against one branch, so the branch's own log grows
  between them: solve time does not follow it.
  """

  use AL

  def install(branch, p) do
    {:atomic, _} =
      run branch: branch.id, trace_mode: :no_trace do
        defmethod(:number, :regsm_entry, [1, 1, 1, 0])

        defmethod(:number, :regsm_entry, [x, a, b, q]) do
          x > 1
          a1 + b1 = q * ^p + a
          a < ^p
          a + 1 > 0
          q + 1 > 0
          b = a1
          x1 = x - 1
          regsm_entry(x1, a1, b1, q1)
        end

        defmethod(:number, :regsm_body, [1, 1, 1, 0])

        defmethod(:number, :regsm_body, [x, a, b, q]) do
          x > 1
          b = a1
          x1 = x - 1
          regsm_body(x1, a1, b1, q1)
          a1 + b1 = q * ^p + a
          a < ^p
          a + 1 > 0
          q + 1 > 0
        end
      end

    :ok
  end

  def entry(branch, n) do
    run branch: branch.id, trace_mode: :no_trace do
      regsm_entry(^n, out, _b, _q)
    end
  end

  def body(branch, n) do
    run branch: branch.id, trace_mode: :no_trace do
      regsm_body(^n, out, _b, _q)
    end
  end

  def expected(n, p) do
    Stream.unfold({1, 1}, fn {a, b} -> {a, {rem(a + b, p), a}} end) |> Enum.at(n - 1)
  end

  def check!(result, n, p) do
    {bindings, _} = Bench.Support.assert_atomic!(result)
    got = Map.get(bindings, :"$out")
    expected = expected(n, p)

    if got != expected do
      raise "regsm result mismatch: expected #{inspect(expected)}, got #{inspect(got)}"
    end
  end

  def variant!("entry"), do: :entry
  def variant!("body"), do: :body

  def variant!(other) do
    raise ArgumentError, "variant must be entry or body, got: #{inspect(other)}"
  end

  def job(variant, p, solve_number \\ 1) do
    Bench.Support.branch_job(
      fn branch, n -> apply(__MODULE__, variant, [branch, n]) end,
      setup: fn branch, n ->
        :ok = install(branch, p)

        if solve_number > 1 do
          for _ <- 1..(solve_number - 1) do
            apply(__MODULE__, variant, [branch, n]) |> check!(n, p)
          end
        end

        :ok
      end,
      check: fn result, n -> check!(result, n, p) end
    )
  end
end

case System.argv() do
  ["repeat", variant, n, p, k] ->
    variant = Bench.Regsm.variant!(variant)
    n = String.to_integer(n)
    p = String.to_integer(p)
    k = String.to_integer(k)

    if k < 1, do: raise(ArgumentError, "repeat count must be positive")

    jobs =
      Map.new(1..k, fn solve_number ->
        {"solve #{solve_number}/#{k} on one branch", Bench.Regsm.job(variant, p, solve_number)}
      end)

    Bench.Support.run(
      jobs,
      title: "Register recurrence — #{variant}, p=#{p}",
      inputs: [{"n=#{n}", n}]
    )

  [variant, n, p] ->
    variant = Bench.Regsm.variant!(variant)
    n = String.to_integer(n)
    p = String.to_integer(p)

    Bench.Support.run(
      %{Atom.to_string(variant) => Bench.Regsm.job(variant, p)},
      title: "Register recurrence — p=#{p}",
      inputs: [{"n=#{n}", n}]
    )

  [variant, from, to, step, p] ->
    variant = Bench.Regsm.variant!(variant)
    from = String.to_integer(from)
    to = String.to_integer(to)
    step = String.to_integer(step)
    p = String.to_integer(p)

    if step < 1, do: raise(ArgumentError, "step must be positive")

    inputs =
      from
      |> Stream.iterate(&(&1 + step))
      |> Enum.take_while(&(&1 <= to))
      |> Enum.map(&{"n=#{&1}", &1})

    Bench.Support.run(
      %{Atom.to_string(variant) => Bench.Regsm.job(variant, p)},
      title: "Register recurrence — p=#{p}",
      inputs: inputs
    )

  _ ->
    raise ArgumentError, """
    usage:
      mix run bench/regsm.exs <entry|body> <n> <p>
      mix run bench/regsm.exs <entry|body> <from> <to> <step> <p>
      mix run bench/regsm.exs repeat <entry|body> <n> <p> <k>
    """
end
