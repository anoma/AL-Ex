defmodule AL.JAM.Collection do
  alias AL.JAM.{Frame, Goals, Operand}

  def collection_store(template, result, slots, store, solutions, branch) do
    template = Operand.resolve(template, slots, store)

    {collected, constraints} =
      Enum.map_reduce(solutions, %{}, fn solution, constraints ->
        {term, copied} = AL.Var.copy_term_with_constraints(template, solution)
        {term, Map.merge(constraints, copied)}
      end)

    store = Map.merge(store, constraints)

    case result do
      {:destination, index} -> {:registers, store, put_elem(slots, index, collected)}
      _ -> AL.Var.unify(Operand.resolve(result, slots, store), collected, store, branch)
    end
  end

  def collection_condition(%Frame{
        code: code,
        pc: pc,
        slots: slots
      }) do
    condition =
      case elem(code, pc) do
        {:collect, _, _, condition} -> condition
        {:collect_n, _, _, _, condition} -> condition
        {:negate, condition} -> condition
        {:forall, _, condition, _, _} -> condition
      end

    Goals.instructions(condition, 0, slots)
  end

  def forall?(%Frame{
        code: code,
        pc: pc
      }),
      do: match?({:forall, _, _, _, _}, elem(code, pc))

  def forall_continuation(
        %Frame{
          id: id,
          code: code,
          pc: pc,
          slots: slots,
          returns: returns,
          store: store,
          pending: pending
        },
        solutions,
        visible
      ) do
    {:forall, operand, _condition, heads, {body, body_values}} = elem(code, pc)
    scope = Integer.to_string(AL.fresh_scope())

    raw_slots =
      slots
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.map(fn {value, index} ->
        if AL.Var.var?(value) and index not in heads,
          do: value,
          else: AL.Var.fresh({:"$var", "forall"}, scope <> ":" <> Integer.to_string(index))
      end)
      |> List.to_tuple()

    raw = Operand.read(operand, raw_slots)
    captures = operand |> Operand.read(slots) |> AL.Var.subst(store)
    visible = AL.Var.find_vars({slots, returns}, visible)
    resolved_slots = body_values |> Operand.read(slots) |> AL.Var.subst(store)

    frames =
      AL.JAM.Forall.instances(raw.condition, raw.body, captures.body, visible, solutions)
      |> Enum.flat_map(fn {connects, freshener, raw_vars} ->
        body_slots = AL.Var.freshen(resolved_slots, freshener, raw_vars)

        bindings =
          Enum.map(connects, fn {left, right} ->
            {id, {{:eq, {:register, 0}, {:register, 1}}}, 0, {left, right}}
          end)

        bindings ++ [{id, body, 0, body_slots}]
      end)

    case frames ++ [{id, code, pc + 1, slots} | returns] do
      [{next_id, next_code, next_pc, next_slots} | rest] ->
        %Frame{
          id: next_id,
          code: next_code,
          pc: next_pc,
          slots: next_slots,
          returns: rest,
          pending: pending
        }
    end
  end

  def collection_continuation(
        %Frame{
          id: id,
          code: code,
          pc: pc,
          slots: slots,
          returns: returns,
          store: store,
          pending: pending
        },
        solutions,
        branch
      ) do
    result =
      case elem(code, pc) do
        {:collect_n, _, template, result, _} ->
          collection_store(template, result, slots, store, solutions, branch)

        {:collect, template, result, _} ->
          collection_store(template, result, slots, store, solutions, branch)

        {:negate, _} ->
          if solutions == [], do: store, else: nil
      end

    case result do
      {:registers, next_store, next_slots} ->
        {%Frame{
           id: id,
           code: code,
           pc: pc + 1,
           slots: next_slots,
           returns: returns,
           pending: pending
         }, next_store}

      next_store ->
        {%Frame{
           id: id,
           code: code,
           pc: pc + 1,
           slots: slots,
           returns: returns,
           pending: pending
         }, next_store}
    end
  end
end
