defmodule AL.JAM.IR.Closure do
  alias AL.{Goal, JAM.IR}

  def static?(body) when is_list(body), do: Enum.all?(body, &static_goal?/1)
  def static?(_), do: false

  defp static_goal?(source) do
    case Goal.from_stored(source) do
      %Goal.Compound{name: name} = goal ->
        not AL.Var.var?(name) and static_lowered?(Goal.lower(goal))

      goal ->
        static_lowered?(Goal.lower(goal))
    end
  end

  defp static_lowered?(goal) do
    case goal do
      %Goal.Or{or: left, then: right} ->
        static?(left) and static?(right)

      %Goal.Implies{condition: condition, then: yes, otherwise: no} ->
        static?(condition) and static?(yes) and static?(no)

      %Goal.Findall{condition: condition} ->
        static?(condition)

      %Goal.Forall{condition: condition, body: body} ->
        static?(condition) and static?(body)

      %Goal.Not{condition: condition} ->
        static?(condition)

      %Goal.Freeze{goals: body} ->
        static?(body)

      %Goal.SourceScope{goals: body} ->
        static?(body)

      goal ->
        IR.lower(goal).kind != :unsupported
    end
  end
end
