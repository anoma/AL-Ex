defmodule AL.JAM.Unification do
  def unify(left, right, store, branch), do: unify(left, right, store, store, branch)

  defp unify(left, right, original, store, branch) do
    left = AL.Var.deref(original, left)
    right = AL.Var.deref(original, right)

    case {left, right} do
      {[head | tail], [other_head | other_tail]} ->
        case unify(head, other_head, original, store, branch) do
          nil -> nil
          next -> unify(tail, other_tail, original, next, branch)
        end

      _ ->
        AL.Var.unify(resolve(left, original), resolve(right, original), store, branch)
    end
  end

  defp resolve(term, _store) when is_atom(term) or is_number(term) or is_binary(term),
    do: term

  defp resolve({:"$fresh", _, _} = term, _store), do: term
  defp resolve(term, store), do: AL.Var.subst(term, store)
end
