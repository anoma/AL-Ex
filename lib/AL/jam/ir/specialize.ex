defmodule AL.JAM.IR.Specialize do
  alias AL.{Goal, Var}
  alias AL.JAM.IR

  defstruct [:original, :goals, :branch, :determinism, :steps, :sends, dependencies: %{}]

  def compile(goals, branch, options \\ []) do
    budget = Keyword.get(options, :budget, 20_000)

    if not (is_integer(budget) and budget > 0),
      do: raise(ArgumentError, "budget must be positive")

    state = %{
      branch: branch,
      remaining: budget,
      steps: 0,
      sends: 0,
      dependencies: %{}
    }

    try do
      variables = goals |> Var.find_vars() |> MapSet.delete(:"$_") |> Enum.sort()
      {solutions, state} = evaluate(Enum.map(goals, &(Goal.lower(&1) |> IR.lower())), %{}, state)

      residual =
        case solutions do
          [] -> [%Goal.Fail{}]
          [store] -> residual(variables, store)
          _ -> throw({:unspecialized, :nondeterministic})
        end

      {:ok,
       %__MODULE__{
         original: goals,
         goals: residual,
         branch: branch,
         determinism: determinism(solutions, residual),
         steps: state.steps,
         sends: state.sends,
         dependencies: state.dependencies
       }}
    catch
      {:unspecialized, reason} -> {:fallback, reason}
    end
  end

  def select(%__MODULE__{} = plan, branch) do
    valid? =
      plan.branch == branch and
        Enum.all?(plan.dependencies, fn {_key, {receiver, selector, method, clauses}} ->
          case AL.Dispatch.target(receiver, selector, branch) do
            {:ok, _, ^method} -> AL.cached_scan_clauses(method, branch) === clauses
            _ -> false
          end
        end)

    if valid? and not AL.JAM.Trace.active?(), do: plan.goals, else: plan.original
  end

  defp determinism([], _goals), do: :failure

  defp determinism(_, goals) do
    if Enum.all?(goals, fn %Goal.Eq{a: a, b: b} -> a === b end), do: :det, else: :semidet
  end

  defp residual(variables, store) do
    if Enum.any?(store, fn {_key, value} -> is_struct(value, AL.Var.ConstraintSet) end),
      do: throw({:unspecialized, :constraints})

    aliases =
      Enum.reduce(variables, %{}, fn variable, aliases ->
        root = Var.deref(store, variable)
        if Var.var?(root), do: Map.put_new(aliases, root, variable), else: aliases
      end)

    values = Enum.map(variables, &Var.subst(&1, store, fn var -> Map.get(aliases, var, var) end))
    original_variables = MapSet.new(variables)

    if not MapSet.subset?(Var.find_vars(values), original_variables),
      do: throw({:unspecialized, :existential_variables})

    Enum.zip(variables, values)
    |> Enum.map(fn {variable, value} -> %Goal.Eq{a: variable, b: value} end)
  end

  defp evaluate([], store, state), do: {[store], state}

  defp evaluate(_operations, _store, %{remaining: 0}),
    do: throw({:unspecialized, :budget})

  defp evaluate([operation | rest], store, state) do
    state = %{state | remaining: state.remaining - 1, steps: state.steps + 1}

    case operation do
      %IR{kind: :direct, name: :pass} ->
        evaluate(rest, store, state)

      %IR{kind: :direct, name: :fail} ->
        {[], state}

      %IR{kind: :direct, name: :eq, args: [a, b]} ->
        a = Var.subst(a, store)
        b = Var.subst(b, store)
        ensure_structural(a)
        ensure_structural(b)
        continue(rest, Var.unify(a, b, store, state.branch), state)

      %IR{kind: :direct, name: :dif, args: [a, b]} ->
        a = Var.subst(a, store)
        b = Var.subst(b, store)
        ensure_structural(a)
        ensure_structural(b)
        continue(rest, Var.dif_value(a, b, store, state.branch), state)

      %IR{kind: :compare, name: op, args: [a, b]} ->
        a = Var.subst(a, store)
        b = Var.subst(b, store)

        if not (is_number(a) and is_number(b)),
          do: throw({:unspecialized, :dynamic_comparison})

        continue(rest, Var.Bounds.compare_value(store, op, a, b, state.branch), state)

      %IR{kind: :branch, args: [left, right]} ->
        alternatives([left, right], rest, store, state)

      %IR{kind: :send, name: selector, args: [receiver, args]} ->
        receiver = Var.subst(receiver, store)
        selector = Var.subst(selector, store)

        if Var.find_vars({receiver, selector}) != MapSet.new(),
          do: throw({:unspecialized, :open_dispatch})

        {clauses, state} = clauses(receiver, selector, state)
        call = [receiver | Var.subst(args, store)]
        ensure_structural(call)
        state = %{state | sends: state.sends + 1}

        Enum.reduce(clauses, {[], state}, fn {:oapply, _, _, head, body}, {solutions, state} ->
          scope = Integer.to_string(AL.fresh_scope())

          {head, body} =
            Goal.map({head, body}, fn term ->
              if Var.var?(term) and term != :"$_", do: Var.fresh(term, scope), else: term
            end)

          ensure_structural(head)
          matched = AL.JAM.Unification.unify(head, call, store, state.branch)

          {next, state} =
            if matched,
              do:
                evaluate(Enum.map(body, &(Goal.lower(&1) |> IR.lower())) ++ rest, matched, state),
              else: {[], state}

          combine(solutions, next, state)
        end)

      %IR{} ->
        throw({:unspecialized, :unsupported_operation})
    end
  end

  defp clauses(receiver, selector, state) do
    key = AL.Dispatch.receiver_key(receiver, selector)

    case Map.fetch(state.dependencies, key) do
      {:ok, {_receiver, _selector, _method, clauses}} ->
        {clauses, state}

      :error ->
        case AL.Dispatch.target(receiver, selector, state.branch) do
          {:ok, _, method} ->
            clauses = AL.cached_scan_clauses(method, state.branch)

            {clauses,
             %{
               state
               | dependencies:
                   Map.put(state.dependencies, key, {receiver, selector, method, clauses})
             }}

          _ ->
            throw({:unspecialized, :unresolved_method})
        end
    end
  end

  defp continue(_rest, nil, state), do: {[], state}
  defp continue(rest, store, state), do: evaluate(rest, store, state)

  defp alternatives(branches, rest, store, state) do
    Enum.reduce(branches, {[], state}, fn branch, {solutions, state} ->
      {next, state} = evaluate(branch ++ rest, store, state)
      combine(solutions, next, state)
    end)
  end

  defp combine(left, right, state) do
    case left ++ right do
      [_, _ | _] -> throw({:unspecialized, :nondeterministic})
      solutions -> {solutions, state}
    end
  end

  defp ensure_structural(term) do
    if Goal.reduce(term, false, fn value, found -> found or value == :"$_" end) or
         contains_compound?(term),
       do: throw({:unspecialized, :unsupported_term})
  end

  defp contains_compound?(%Goal.Compound{}), do: true
  defp contains_compound?([head | tail]), do: contains_compound?(head) or contains_compound?(tail)

  defp contains_compound?(term) when is_map(term),
    do:
      Enum.any?(term, fn {key, value} -> contains_compound?(key) or contains_compound?(value) end)

  defp contains_compound?(_), do: false
end
