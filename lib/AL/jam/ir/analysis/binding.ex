defmodule AL.JAM.IR.Binding do
  alias AL.Var

  def fresh?(term, exposed),
    do: Var.var?(term) and term != {:"$var", "_"} and not MapSet.member?(exposed, term)

  def infer(a, b, exposed), do: candidate(a, b, exposed) || candidate(b, a, exposed)

  def infer_structural(a, b, exposed),
    do: structural_candidate(a, b, exposed) || structural_candidate(b, a, exposed)

  defp structural_candidate(variable, value, exposed) do
    vars = Var.find_vars(value)

    if fresh?(variable, exposed) and not MapSet.member?(vars, variable) and
         not MapSet.member?(vars, {:"$var", "_"}),
       do: {variable, value}
  end

  def escape(operation, exposed), do: MapSet.union(exposed, AL.JAM.IR.variables(operation))

  defp candidate(variable, value, exposed) do
    vars = Var.find_vars(value)

    if fresh?(variable, exposed) and not MapSet.member?(vars, variable) and
         not MapSet.member?(vars, {:"$var", "_"}) do
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
