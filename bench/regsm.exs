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
      run branch: branch.id do
        defmethod(:number, :regsm_entry, [1, 1, 1, 0])

        defmethod(:number, :regsm_entry, [x, a, b, q]) do
          x > 1
          eq(a1 + b1, q * ^p + a)
          a < ^p
          a + 1 > 0
          q + 1 > 0
          unify(b, a1)
          vm_is(x1, x - 1)
          regsm_entry(x1, a1, b1, q1)
        end

        defmethod(:number, :regsm_body, [1, 1, 1, 0])

        defmethod(:number, :regsm_body, [x, a, b, q]) do
          x > 1
          unify(b, a1)
          vm_is(x1, x - 1)
          regsm_body(x1, a1, b1, q1)
          eq(a1 + b1, q * ^p + a)
          a < ^p
          a + 1 > 0
          q + 1 > 0
        end
      end

    :ok
  end

  def entry(branch, n) do
    run branch: branch.id do
      regsm_entry(^n, out, _b, _q)
    end
  end

  def body(branch, n) do
    run branch: branch.id do
      regsm_body(^n, out, _b, _q)
    end
  end

  def expected(n, p) do
    Stream.unfold({1, 1}, fn {a, b} -> {a, {rem(a + b, p), a}} end) |> Enum.at(n - 1)
  end

  def status(result, n, p) do
    case result do
      {:atomic, {bindings, _}} ->
        got = Map.get(bindings, :"$out")
        if got == expected(n, p), do: "ok", else: "MISMATCH got=#{inspect(got)}"

      {:aborted, %{reason: reason}} ->
        "aborted: #{inspect(reason)}"

      other ->
        inspect(other)
    end
  end

  def report(variant, n, p) do
    branch = AL.Branch.fork()
    :ok = install(branch, p)
    {time_us, result} = :timer.tc(fn -> apply(__MODULE__, variant, [branch, n]) end)
    AL.Branch.discard(branch)

    IO.puts(
      "#{variant}\tp=#{p}\tn=#{n}\t#{Float.round(time_us / 1000, 1)}ms\t#{status(result, n, p)}"
    )
  end

  def repeat(variant, n, p, k) do
    branch = AL.Branch.fork()
    :ok = install(branch, p)

    for i <- 1..k do
      {time_us, result} = :timer.tc(fn -> apply(__MODULE__, variant, [branch, n]) end)

      IO.puts(
        "#{variant}\tp=#{p}\tn=#{n}\tsolve #{i}/#{k} on one branch" <>
          "\t#{Float.round(time_us / 1000, 1)}ms\t#{status(result, n, p)}"
      )
    end

    AL.Branch.discard(branch)
  end
end

GtBridge.Xref.wait_until_ready()

case System.argv() do
  ["repeat", variant, n, p, k] ->
    Bench.Regsm.repeat(
      String.to_atom(variant),
      String.to_integer(n),
      String.to_integer(p),
      String.to_integer(k)
    )

  [variant, n, p] ->
    Bench.Regsm.report(String.to_atom(variant), String.to_integer(n), String.to_integer(p))

  [variant, from, to, step, p] ->
    p = String.to_integer(p)

    String.to_integer(from)
    |> Stream.iterate(&(&1 + String.to_integer(step)))
    |> Enum.take_while(&(&1 <= String.to_integer(to)))
    |> Enum.each(&Bench.Regsm.report(String.to_atom(variant), &1, p))
end
