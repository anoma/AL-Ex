defmodule AL.JAM.IR.MethodSummary do
  alias AL.JAM.IR.{Dataflow, Inference, Program, Region}

  defstruct [
    :program,
    inputs: [],
    bindings: %{},
    reads: MapSet.new(),
    writes: MapSet.new(),
    determinism: :unknown,
    suspension: :unknown,
    effect: :unknown
  ]

  def infer(program, arguments, exposed) do
    observable = MapSet.union(exposed, AL.Var.find_vars(arguments))

    analysis =
      program
      |> Region.combine_blocks()
      |> Dataflow.analyze(observable, true, exposed)

    program = Dataflow.eliminate_dead_bindings(analysis)
    facts = for {_, block} <- analysis.inference, {_, fact} <- block, do: fact
    linear = not Program.branching?(program)
    failure = Enum.any?(program.blocks, fn {_, block} -> block.exit == :fail end)

    %__MODULE__{
      program: program,
      inputs: Enum.map(arguments, &Inference.mode(&1, exposed)),
      bindings: if(linear and analysis.return_facts, do: analysis.return_facts.values, else: %{}),
      reads: union(analysis.uses),
      writes: union(analysis.defines),
      determinism: if(linear, do: determinism(facts, failure), else: :unknown),
      suspension: if(Enum.all?(facts, &(&1.suspension == :never)), do: :never, else: :unknown),
      effect: if(Enum.all?(facts, &transparent?/1), do: :local, else: :unknown)
    }
  end

  def transparent?(%{suspension: :never, effect: effect}) when effect in [:pure, :local], do: true
  def transparent?(_), do: false

  defp union(sets),
    do: Enum.reduce(sets, MapSet.new(), fn {_, set}, acc -> MapSet.union(acc, set) end)

  defp determinism(facts, failure) do
    cond do
      not failure and Enum.all?(facts, &(&1.determinism == :det)) -> :det
      Enum.all?(facts, &(&1.determinism in [:det, :semidet])) -> :semidet
      true -> :unknown
    end
  end
end
