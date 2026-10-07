defmodule AL.JAM.IR.Inference do
  alias AL.{JAM.IR, Var}

  defstruct determinism: :unknown,
            suspension: :unknown,
            effect: :unknown,
            binding: nil,
            modes: [],
            access: []

  def operation(%IR{} = operation, exposed) do
    modes = Enum.map(operation.args, &mode(&1, exposed))

    infer(operation, exposed)
    |> Map.put(:modes, modes)
    |> Map.put(:access, IR.Access.modes(operation))
  end

  def sequence(operations) do
    Enum.reduce(
      operations,
      %__MODULE__{determinism: :det, suspension: :never, effect: :pure},
      fn operation, summary ->
        %{
          summary
          | determinism: join_determinism(summary.determinism, operation.determinism),
            suspension:
              if(summary.suspension == :never and operation.suspension == :never,
                do: :never,
                else: :unknown
              ),
            effect:
              if(summary.effect in [:pure, :local] and operation.effect in [:pure, :local],
                do: :local,
                else: :unknown
              )
        }
      end
    )
  end

  defp join_determinism(:unknown, _), do: :unknown
  defp join_determinism(_, :unknown), do: :unknown
  defp join_determinism(:det, :det), do: :det
  defp join_determinism(_, _), do: :semidet

  def mode(term, exposed) do
    cond do
      MapSet.size(Var.find_vars(term)) == 0 -> :ground
      Var.var?(term) and term != :"$_" and not MapSet.member?(exposed, term) -> :fresh
      true -> :unknown
    end
  end

  defp infer(%IR{kind: :direct, name: :pass}, _),
    do: %__MODULE__{determinism: :det, suspension: :never, effect: :pure}

  defp infer(%IR{kind: :direct, name: :eq, args: [a, b]}, exposed) do
    case binding(a, b, exposed) || binding(b, a, exposed) do
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

  defp binding(variable, value, exposed) do
    vars = Var.find_vars(value)

    if mode(variable, exposed) == :fresh and not MapSet.member?(vars, variable) and
         not MapSet.member?(vars, :"$_") do
      if Var.Bounds.arithmetic?(value) do
        if MapSet.size(vars) == 0 do
          case Var.Bounds.eval(value, %{}) do
            number when is_number(number) -> {variable, number}
            _ -> nil
          end
        end
      else
        {variable, value}
      end
    end
  end
end
