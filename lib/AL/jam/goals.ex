defmodule AL.JAM.Goals do
  alias AL.Goal
  alias AL.JAM.Operand

  defp context_method(:tx_id), do: :vm_current_tx
  defp context_method(:transaction_object), do: :vm_transaction_object

  def instructions(code, pc, slots) do
    code
    |> Tuple.to_list()
    |> Enum.drop(pc)
    |> Enum.flat_map(fn
      {:numeric_tests, _, _, fallback} -> instructions(fallback, 0, slots)
      operation -> [instruction(operation, slots)]
    end)
  end

  def instruction({:move, _, _}, _), do: %Goal.Pass{}
  def instruction({:jump, _, _}, _), do: %Goal.Pass{}
  def instruction({:try, _, _}, _), do: %Goal.Pass{}
  def instruction({:get_cons, _, _, _, _}, _), do: %Goal.Pass{}

  def instruction({:cursor, _index}, _slots), do: %Goal.Pass{}

  def instruction({:next, _cursor, self, args}, slots),
    do: %Goal.CallNextMethod{self: Operand.read(self, slots), args: Operand.read(args, slots)}

  def instruction({:call_method, method, args}, slots),
    do: %Goal.OApply{method_id: Operand.read(method, slots), args: Operand.read(args, slots)}

  def instruction({:send, _site, object, method, args}, slots),
    do: %Goal.Send{
      object: Operand.read(object, slots),
      method: Operand.read(method, slots),
      args: Operand.read(args, slots)
    }

  def instruction({:branch, left, right}, slots),
    do: %Goal.Or{or: instructions(left, 0, slots), then: instructions(right, 0, slots)}

  def instruction({:condition, condition, otherwise}, slots) do
    {:commit, then} = elem(condition, tuple_size(condition) - 1)
    condition = condition |> Tuple.to_list() |> Enum.drop(-1) |> List.to_tuple()

    %Goal.Implies{
      condition: instructions(condition, 0, slots),
      then: instructions(then, 0, slots),
      otherwise: instructions(otherwise, 0, slots)
    }
  end

  def instruction({:commit, then}, slots),
    do: %Goal.Implies{condition: [], then: instructions(then, 0, slots), otherwise: []}

  def instruction({:send_local, operation, _destinations}, slots),
    do: instruction(operation, slots)

  def instruction({:integer_arithmetic, _, _, _, _, fallback}, slots),
    do: instruction(fallback, slots)

  def instruction({:local, _index, operation}, slots), do: instruction(operation, slots)

  def instruction({:forall, _captures, condition, _heads, {body, values}}, slots),
    do: %Goal.Forall{
      condition: instructions(condition, 0, slots),
      body: instructions(body, 0, Operand.read(values, slots))
    }

  def instruction({:constraint, operation, arguments}, slots),
    do: AL.JAM.Constraint.goal(operation, Enum.map(arguments, &Operand.read(&1, slots)))

  def instruction({:label, _site, term}, slots),
    do: %Goal.Label{term: Operand.read(term, slots)}

  def instruction({:collect_n, count, template, result, condition}, slots),
    do: %Goal.FindNSols{
      count: Operand.read(count, slots),
      template: Operand.read(template, slots),
      result: Operand.read(result, slots),
      condition: instructions(condition, 0, slots)
    }

  def instruction({:collect, template, result, condition}, slots),
    do: %Goal.Findall{
      template: Operand.read(template, slots),
      result: Operand.read(result, slots),
      condition: instructions(condition, 0, slots)
    }

  def instruction({:call, _site, head, body, args}, slots),
    do: %Goal.Call{
      head: Operand.read(head, slots),
      body: Operand.read(body, slots),
      args: Operand.read(args, slots)
    }

  def instruction({:eq, a, b}, slots),
    do: %Goal.Eq{a: Operand.read(a, slots), b: Operand.read(b, slots)}

  def instruction({:unify_structural, a, b}, slots),
    do: %Goal.OApply{
      method_id: :map_get,
      args: [%{value: Operand.read(b, slots)}, :value, Operand.read(a, slots)]
    }

  def instruction({:dif, a, b}, slots),
    do: %Goal.Dif{a: Operand.read(a, slots), b: Operand.read(b, slots)}

  def instruction({:compare, op, a, b}, slots),
    do: %Goal.Compare{op: op, a: Operand.read(a, slots), b: Operand.read(b, slots)}

  def instruction({:ground, term}, slots), do: %Goal.Ground{term: Operand.read(term, slots)}
  def instruction({:is_var, term}, slots), do: %Goal.IsVar{term: Operand.read(term, slots)}

  def instruction({:map_get, map, key, value}, slots),
    do: %Goal.OApply{
      method_id: :map_get,
      args: [Operand.read(map, slots), Operand.read(key, slots), Operand.read(value, slots)]
    }

  def instruction({:map_put, map, key, value, result}, slots),
    do: %Goal.OApply{
      method_id: :vm_map_put,
      args: [
        Operand.read(map, slots),
        Operand.read(key, slots),
        Operand.read(value, slots),
        Operand.read(result, slots)
      ]
    }

  def instruction({:slot_get, object, key, value, storage}, slots),
    do: %Goal.GetSlots{
      object: Operand.read(object, slots),
      key: Operand.read(key, slots),
      value: Operand.read(value, slots),
      store: Operand.read(storage, slots)
    }

  def instruction({:negate, condition}, slots),
    do: %Goal.Not{condition: instructions(condition, 0, slots)}

  def instruction({:freeze, variable, code}, slots),
    do: %Goal.Freeze{var: Operand.read(variable, slots), goals: instructions(code, 0, slots)}

  def instruction({:context, field, result}, slots),
    do: %Goal.OApply{method_id: context_method(field), args: [Operand.read(result, slots)]}

  def instruction({:mutation, operation, arguments}, slots),
    do: AL.JAM.Mutation.goal(operation, Enum.map(arguments, &Operand.read(&1, slots)))

  def instruction({:relation, operation, arguments}, slots),
    do: AL.JAM.Relation.goal(operation, Enum.map(arguments, &Operand.read(&1, slots)))

  def instruction({:primitive, operation, arguments}, slots),
    do: AL.JAM.Primitive.goal(operation, Enum.map(arguments, &Operand.read(&1, slots)))

  def instruction(:cut_scope, _slots), do: %Goal.Pass{}
  def instruction(:progress, _slots), do: %Goal.Pass{}
  def instruction(:cut, _slots), do: %Goal.Cut{}
  def instruction(:pass, _slots), do: %Goal.Pass{}

  def instruction({:source_scope, capture_id, goals, _body}, slots),
    do: %Goal.SourceScope{
      capture_id: Operand.read(capture_id, slots),
      goals: Operand.read(goals, slots)
    }

  def instruction({:send_as, provider_id, _cursor, call}, slots),
    do: %Goal.OApply{method_id: provider_id, args: Operand.read(call, slots)}

  def instruction({:copy_term, term, copy, goals}, slots),
    do: %Goal.CopyTerm{
      term: Operand.read(term, slots),
      copy: Operand.read(copy, slots),
      goals: Operand.read(goals, slots)
    }

  def instruction({:format, control, args}, slots),
    do: %Goal.Format{control: Operand.read(control, slots), args: Operand.read(args, slots)}

  def instruction(:fail, _slots), do: %Goal.Fail{}
end
