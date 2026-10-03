defmodule AL.PreparedHeadMatcherTest do
  use ExUnit.Case, async: true

  test "prepared matching agrees with general fresh unification" do
    scope = "prepared-match"
    branch = AL.Branch.head()

    heads = [
      [],
      [:"$_"],
      [:"$_", :fixed],
      [:"$X"],
      [:"$X", :"$X"],
      [:"$X", :fixed],
      [:fixed, :"$X"],
      [:"$X", :"$Y", :"$X"],
      [[:fixed | :"$Tail"], :"$X"],
      [{:pair, :"$X", :"$Y"}],
      [%{class: :sample, value: :"$X"}],
      [{:"$fresh", :"$X", "older"}]
    ]

    calls = [
      [],
      [:fixed],
      [:other],
      [:"$A"],
      [:fixed, :fixed],
      [:fixed, :other],
      [:"$A", :"$B"],
      [:"$A", :"$A"],
      [:fixed, :"$A", :"$B"],
      [:"$A", :"$B", :"$A"],
      [:"$A" | :"$Tail"],
      [[:fixed, :other], :fixed],
      [{:pair, :fixed, :other}],
      [%{class: :sample, value: :fixed}],
      [{:"$fresh", :"$A", "caller"}]
    ]

    stores = [
      %{},
      %{:"$A" => :fixed},
      %{:"$A" => :"$B"},
      AL.Var.add_dif(%{}, :"$A", :fixed),
      AL.Var.add_isa(%{}, :"$A", :number)
    ]

    {:atomic, comparisons} =
      :mnesia.transaction(fn ->
        for head <- heads, call <- calls, store <- stores do
          prepared = plan(head)
          expected = AL.Var.unify_fresh(AL.Var.freshen(head, scope), call, store, branch, scope)
          actual = AL.Var.unify_fresh_prepared(prepared, call, store, branch, scope)
          {head, call, store, expected, actual}
        end
      end)

    for {head, call, store, expected, actual} <- comparisons do
      assert actual == expected,
             "head=#{inspect(head)} call=#{inspect(call)} store=#{inspect(store)}"
    end
  end

  defp plan(:"$_"), do: :wildcard
  defp plan({:"$fresh", _, _} = variable), do: {:variable, variable}
  defp plan([head | tail] = original), do: {:cons, original, plan(head), plan(tail)}

  defp plan(term) when is_tuple(term),
    do: {:tuple, term, tuple_size(term), term |> Tuple.to_list() |> Enum.map(&plan/1)}

  defp plan(term) when is_map(term), do: {:fallback, term}

  defp plan(term) when is_atom(term),
    do: if(AL.Var.var?(term), do: {:variable, term}, else: {:literal, term})

  defp plan(term), do: {:literal, term}
end
