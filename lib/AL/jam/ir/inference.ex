defmodule AL.JAM.IR.Inference do
  alias AL.{JAM.IR, Var}

  defstruct determinism: :unknown,
            suspension: :unknown,
            effect: :unknown,
            binding: nil,
            modes: [],
            access: []

  def operation(%IR{} = operation, exposed) do
    modes = Enum.map(IR.Access.values(operation), &mode(&1, exposed))

    infer(operation, exposed)
    |> Map.put(:modes, modes)
    |> Map.put(:access, IR.Access.modes(operation))
  end

  def mode(term, exposed) do
    cond do
      MapSet.size(Var.find_vars(term)) == 0 -> :ground
      IR.Binding.fresh?(term, exposed) -> :fresh
      true -> :unknown
    end
  end

  defp infer(%IR{kind: :direct, name: :pass}, _),
    do: %__MODULE__{determinism: :det, suspension: :never, effect: :pure}

  defp infer(%IR{kind: :direct, name: :eq, args: [a, b]}, exposed) do
    case IR.Binding.infer(a, b, exposed) do
      nil ->
        %__MODULE__{effect: :binding}

      binding ->
        %__MODULE__{determinism: :det, suspension: :never, effect: :local, binding: binding}
    end
  end

  defp infer(%IR{kind: :compare, args: args}, exposed) do
    if Enum.all?(args, &(mode(&1, exposed) == :ground and is_number(&1))),
      do: %__MODULE__{determinism: :semidet, suspension: :never, effect: :pure},
      else: %__MODULE__{effect: :constraint}
  end

  defp infer(operation, _), do: %__MODULE__{effect: IR.effects(operation)}
end
