defmodule AL.JAM.Unification do
  def unify(left, right, store, branch), do: unify(left, right, store, store, branch)

  def different(left, right, store, branch) do
    case unify(left, right, store, branch) do
      nil -> store
      ^store -> nil
      _ -> AL.Var.add_dif(store, AL.Var.subst(left, store), AL.Var.subst(right, store))
    end
  end

  defp unify(left, right, original, store, branch) do
    raw_left = left
    raw_right = right
    left = AL.Var.deref(original, left)
    right = AL.Var.deref(original, right)

    case {left, right} do
      {[head | tail], [other_head | other_tail]} ->
        case unify(head, other_head, original, store, branch) do
          nil -> nil
          next -> unify(tail, other_tail, original, next, branch)
        end

      _ ->
        if AL.Var.var?(left) or AL.Var.var?(right) do
          AL.Var.unify(raw_left, raw_right, store, branch)
        else
          AL.Var.unify(resolve(left, original), resolve(right, original), store, branch)
        end
    end
  end

  defp resolve(term, _store) when is_atom(term) or is_number(term) or is_binary(term),
    do: term

  defp resolve({:"$var", _} = term, _store), do: term

  defp resolve({:"$fresh", _, _} = term, _store), do: term
  defp resolve(term, store), do: AL.Var.subst(term, store)
end
