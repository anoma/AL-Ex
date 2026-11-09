defmodule AL.JAM.Instruction do
  alias AL.JAM.Operand
  alias AL.JAM.IR.Program

  @type register() :: non_neg_integer()
  @type address() :: atom() | non_neg_integer()
  @type code() :: Program.t() | [t()] | tuple()

  @type runtime_action() ::
          {:assert_valid_clause_self, term(), term()}
          | {:emit_effect, term(), term(), term(), term()}
          | {:await, term()}
          | {:send_elixir, term(), term()}
          | {:set_class, term(), term()}
          | {:set_super, term(), term()}
          | {:set_method, term(), term(), term()}
          | {:set_oapply, term(), term(), term(), term()}
          | {:set_slot, term(), term(), term()}
          | {:slot_batch, term()}
          | {:retract_class, term(), term()}
          | {:retract_super, term(), term()}
          | {:retract_method, term(), term(), term()}
          | {:retract_oapply, term(), term()}
          | {:retract_slot, term(), term()}

  @type t() ::
          :pass
          | :fail
          | :cut
          | :cut_scope
          | {:eq, left :: term(), right :: term()}
          | {:unify_structural, left :: term(), right :: term()}
          | {:dif, left :: term(), right :: term()}
          | {:dif, input :: register(), bound :: number(), input_side :: :left | :right}
          | {:compare, operator :: atom(), left :: term(), right :: term()}
          | {:compare, operator :: atom(), input :: register(), bound :: number(),
             input_side :: :left | :right}
          | {:ground, term()}
          | {:is_var, term()}
          | {:map_get, map :: term(), key :: term(), value :: term()}
          | {:map_put, map :: term(), key :: term(), value :: term(), result :: term()}
          | {:slot_get, object :: term(), key :: term(), value :: term(), storage :: term()}
          | {:primitive, name :: atom(), arguments :: [term()]}
          | {:constraint, name :: atom(), arguments :: [term()]}
          | {:relation, name :: atom(), arguments :: [term()]}
          | runtime_action()
          | {:context, field :: atom(), result :: term()}
          | {:label, site :: term(), value :: term()}
          | {:send, site :: term(), receiver :: term(), selector :: term(), arguments :: term()}
          | {:call_method, method :: term(), arguments :: term()}
          | {:call_method, method :: term(), arguments :: term(), capture :: term()}
          | {:call, site :: term(), head :: term(), body :: term(), arguments :: term()}
          | {:next, cursor :: term(), receiver :: term(), arguments :: term()}
          | {:collect, template :: term(), result :: term(), condition :: code()}
          | {:collect_n, count :: term(), template :: term(), result :: term(),
             condition :: code()}
          | {:negate, condition :: code()}
          | {:freeze, variable :: term(), body :: code()}
          | {:condition, condition :: code(), otherwise :: code()}
          | {:commit, then :: code()}
          | {:move, destination :: register(), source :: term()}
          | {:jump, target :: address(), transfers :: [{register(), term()}]}
          | {:get_cons, source :: term(), head :: register(), tail :: register(),
             failure :: address()}
          | {:try, alternative :: address(), live :: [register()]}
          | {:try, alternative :: address(), live :: [register()], target :: address()}
          | {:numeric_tests, value :: term(), tests :: [{atom(), number()}], fallback :: code()}
          | {:integer_arithmetic, operator :: :+ | :- | :*, destination :: register(),
             left :: term(), right :: term(), fallback :: t()}
          | {:eq_into, destination :: register(), source :: term(),
             destination_side :: :left | :right}
          | {:unify_structural_into, destination :: register(), source :: term(),
             destination_side :: :left | :right}
          | {:map_get_into, destination :: register(), map :: term(), key :: term()}
          | {:slot_get_into, destination :: register(), object :: term(), key :: term(),
             storage :: term()}
          | {:map_put_into, destination :: register(), map :: term(), key :: term(),
             value :: term()}
          | {:primitive_into, destination :: register(), name :: atom(), output_position :: 0 | 1,
             input :: term()}
          | {:send_local, instruction :: t(), destinations :: [register()]}

  @spec into(t(), register()) :: t()
  def into({:eq, {:register, destination}, source}, destination),
    do: {:eq_into, destination, source, :left}

  def into({:eq, source, {:register, destination}}, destination),
    do: {:eq_into, destination, source, :right}

  def into({:unify_structural, {:register, destination}, source}, destination),
    do: {:unify_structural_into, destination, source, :left}

  def into({:unify_structural, source, {:register, destination}}, destination),
    do: {:unify_structural_into, destination, source, :right}

  def into({:map_get, map, key, _result}, destination),
    do: {:map_get_into, destination, map, key}

  def into({:slot_get, object, key, _result, storage}, destination),
    do: {:slot_get_into, destination, object, key, storage}

  def into({:map_put, map, key, value, _result}, destination),
    do: {:map_put_into, destination, map, key, value}

  def into({:primitive, name, [{:register, destination}, input]}, destination),
    do: {:primitive_into, destination, name, 0, input}

  def into({:primitive, name, [input, {:register, destination}]}, destination),
    do: {:primitive_into, destination, name, 1, input}

  @spec general(t()) :: t()
  def general({:compare, op, input, bound, :left}),
    do: {:compare, op, {:register, input}, {:constant, bound}}

  def general({:compare, op, input, bound, :right}),
    do: {:compare, AL.JAM.Arithmetic.reverse(op), {:constant, bound}, {:register, input}}

  def general({:dif, input, bound, :left}),
    do: {:dif, {:register, input}, {:constant, bound}}

  def general({:dif, input, bound, :right}),
    do: {:dif, {:constant, bound}, {:register, input}}

  def general({:eq_into, destination, source, :left}),
    do: {:eq, {:register, destination}, source}

  def general({:eq_into, destination, source, :right}),
    do: {:eq, source, {:register, destination}}

  def general({:unify_structural_into, destination, source, :left}),
    do: {:unify_structural, {:register, destination}, source}

  def general({:unify_structural_into, destination, source, :right}),
    do: {:unify_structural, source, {:register, destination}}

  def general({:map_get_into, destination, map, key}),
    do: {:map_get, map, key, {:register, destination}}

  def general({:slot_get_into, destination, object, key, storage}),
    do: {:slot_get, object, key, {:register, destination}, storage}

  def general({:map_put_into, destination, map, key, value}),
    do: {:map_put, map, key, value, {:register, destination}}

  def general({:primitive_into, destination, name, 0, input}),
    do: {:primitive, name, [{:register, destination}, input]}

  def general({:primitive_into, destination, name, 1, input}),
    do: {:primitive, name, [input, {:register, destination}]}

  def general(instruction), do: instruction

  def operands({family, _name, args})
      when family in [:primitive, :constraint, :relation],
      do: args

  def operands({:call_method, {:method_identity, _, _}, args}), do: [args]
  def operands({:call_method, {:method_identity, _, _}, args, _capture}), do: [args]

  def operands(instruction) do
    case runtime_action_operands(instruction) do
      {:ok, operands} -> operands
      :error -> Enum.map(operand_positions(instruction), &elem(instruction, &1))
    end
  end

  def map_operands({family, name, args}, fun)
      when family in [:primitive, :constraint, :relation],
      do: {family, name, Enum.map(args, fun)}

  def map_operands({:call_method, {:method_identity, _, _} = method, args}, fun),
    do: {:call_method, method, fun.(args)}

  def map_operands({:call_method, {:method_identity, _, _} = method, args, capture}, fun),
    do: {:call_method, method, fun.(args), capture}

  def map_operands(instruction, fun) do
    case runtime_action_operands(instruction) do
      {:ok, operands} ->
        List.to_tuple([elem(instruction, 0) | Enum.map(operands, fun)])

      :error ->
        Enum.reduce(operand_positions(instruction), instruction, fn index, result ->
          put_elem(result, index, fun.(elem(instruction, index)))
        end)
    end
  end

  @spec runtime_action_operands(term()) :: {:ok, [term()]} | :error
  def runtime_action_operands({:assert_valid_clause_self, class, head}),
    do: {:ok, [class, head]}

  def runtime_action_operands({:emit_effect, effect, provider, operation, arguments}),
    do: {:ok, [effect, provider, operation, arguments]}

  def runtime_action_operands({:await, target}), do: {:ok, [target]}
  def runtime_action_operands({:send_elixir, pid, message}), do: {:ok, [pid, message]}
  def runtime_action_operands({:set_class, object, class}), do: {:ok, [object, class]}
  def runtime_action_operands({:set_super, object, super}), do: {:ok, [object, super]}
  def runtime_action_operands({:set_method, object, name, id}), do: {:ok, [object, name, id]}

  def runtime_action_operands({:set_oapply, object, seq, head, body}),
    do: {:ok, [object, seq, head, body]}

  def runtime_action_operands({:set_slot, object, key, value}),
    do: {:ok, [object, key, value]}

  def runtime_action_operands({:slot_batch, writes}), do: {:ok, [writes]}
  def runtime_action_operands({:retract_class, object, class}), do: {:ok, [object, class]}
  def runtime_action_operands({:retract_super, object, super}), do: {:ok, [object, super]}

  def runtime_action_operands({:retract_method, object, name, id}),
    do: {:ok, [object, name, id]}

  def runtime_action_operands({:retract_oapply, object, head}), do: {:ok, [object, head]}
  def runtime_action_operands({:retract_slot, object, key}), do: {:ok, [object, key]}
  def runtime_action_operands(_), do: :error

  defp operand_positions(instruction) do
    case instruction do
      op when op in [:pass, :fail, :cut] -> []
      {:compare, _, _, _} -> [2, 3]
      {:context, _, _} -> [2]
      {:numeric_tests, _, _, _} -> [1]
      {:send, _, _, _, _} -> [2, 3, 4]
      {:call, _, _, _, _} -> [2, 3, 4]
      {:label, _, _} -> [2]
      {:next, _, _, _} -> [2, 3]
      {:collect, _, _, _} -> [1, 2]
      {:collect_n, _, _, _, _} -> [1, 2, 3]
      {:negate, _} -> []
      {:freeze, _, _} -> [1]
      {:call_method, _, _, _} -> [1, 2]
      {op, _} when op in [:ground, :is_var] -> [1]
      {op, _, _} when op in [:eq, :dif, :unify_structural, :call_method] -> [1, 2]
      {:map_get, _, _, _} -> [1, 2, 3]
      {op, _, _, _, _} when op in [:map_put, :slot_get] -> [1, 2, 3, 4]
    end
  end

  def map_values({:numeric_tests, value, tests, fallback}, fun),
    do: {:numeric_tests, AL.Term.map(value, fun), tests, Enum.map(fallback, &map_values(&1, fun))}

  def map_values(instruction, fun) do
    instruction
    |> map_operands(&AL.Term.map(&1, fun))
    |> map_regions(&Program.map_values(&1, fun))
  end

  def variables(instruction) do
    Enum.reduce(regions(instruction), AL.Var.find_vars(operands(instruction)), fn {_, body},
                                                                                  vars ->
      MapSet.union(vars, Program.variables(body))
    end)
  end

  def regions({:collect, _, _, condition}), do: [condition: condition]
  def regions({:collect_n, _, _, _, condition}), do: [condition: condition]
  def regions({:negate, condition}), do: [condition: condition]
  def regions({:freeze, _, goals}), do: [goals: goals]
  def regions(_), do: []

  defp map_regions({:collect, template, result, condition}, fun),
    do: {:collect, template, result, fun.(condition)}

  defp map_regions({:collect_n, count, template, result, condition}, fun),
    do: {:collect_n, count, template, result, fun.(condition)}

  defp map_regions({:negate, condition}, fun), do: {:negate, fun.(condition)}
  defp map_regions({:freeze, var, goals}, fun), do: {:freeze, var, fun.(goals)}

  defp map_regions(instruction, _fun), do: instruction

  def scoped?(instruction), do: regions(instruction) != []

  def contains?(program, name) do
    Program.any?(program, fn instruction ->
      control?(instruction, name) or
        Enum.any?(regions(instruction), fn {_, child} -> contains?(child, name) end)
    end)
  end

  defp control?(:cut, :cut), do: true
  defp control?({:next, _, _, _}, :next), do: true
  defp control?(_, _), do: false

  def local?(instruction) do
    case instruction do
      op when op in [:pass, :fail] ->
        true

      {:primitive, name, _}
      when name in [
             :variant,
             :equal,
             :string_codes,
             :atom_string,
             :atom,
             :functor,
             :copy_term,
             :map_pairs,
             :block_goals
           ] ->
        true

      {op, _} when op in [:ground, :is_var] ->
        true

      {op, _, _} when op in [:eq, :dif, :unify_structural] ->
        true

      {op, _, _, _} when op in [:compare, :map_get] ->
        true

      {op, _, _, _, _} when op in [:slot_get, :map_put] ->
        true

      _ ->
        false
    end
  end

  def effects(:pass), do: :pure
  def effects({op, _, _}) when op in [:eq, :dif, :unify_structural], do: :binding
  def effects({:relation, _, _}), do: :read_and_bind
  def effects(:cut), do: :control
  def effects({:next, _, _, _}), do: :control

  def effects(instruction) do
    case runtime_action_operands(instruction) do
      {:ok, _} -> :write
      :error -> if(scoped?(instruction), do: :scoped, else: :unknown)
    end
  end

  defp materialize_local(slots, index) do
    if elem(slots, index) == nil,
      do:
        put_elem(
          slots,
          index,
          AL.Var.fresh({:"$var", "Local"}, Integer.to_string(AL.Scope.fresh()))
        ),
      else: slots
  end

  defp fallback(operation, index, slots),
    do: {:fallback, materialize_local(slots, index), general(operation)}

  defp assign_local(index, source, slots, store, branch) do
    value = AL.JAM.IR.Access.resolve(:direct, :eq, source, slots, store)

    cond do
      value == {:"$var", "_"} ->
        {:registers, store, materialize_local(slots, index)}

      AL.Var.Bounds.arithmetic?(value) ->
        case AL.Var.Bounds.eval(value, store) do
          number when is_number(number) ->
            {:registers, store, put_elem(slots, index, number)}

          :error ->
            slots = materialize_local(slots, index)

            case AL.Var.unify_value(elem(slots, index), value, store, branch) do
              nil -> nil
              next_store -> {:registers, next_store, slots}
            end
        end

      true ->
        {:registers, store, put_elem(slots, index, value)}
    end
  end

  def execute(operation, slots, store, branch, pending \\ %{})

  # Apply arithmetic op, fallback otherwise
  def execute(
        {:integer_arithmetic, op, destination, a, b, fallback},
        slots,
        store,
        branch,
        pending
      ) do
    left = Operand.read(a, slots)
    right = Operand.read(b, slots)

    if is_integer(left) and is_integer(right) do
      value =
        case op do
          :+ -> left + right
          :- -> left - right
          :* -> left * right
        end

      {:registers, store, put_elem(slots, destination, value)}
    else
      AL.JAM.Trace.fallback(fallback, slots)
      execute(fallback, slots, store, branch, pending)
    end
  end

  # Structural unification fast-path when one side is a fresh var
  def execute({:unify_structural_into, index, source, _side}, slots, store, _branch, _pending) do
    {:registers, store, put_elem(slots, index, Operand.resolve(source, slots, store))}
  end

  # Constraint equality fast-path
  def execute({:eq_into, index, source, _side}, slots, store, branch, _pending) do
    case AL.JAM.Arithmetic.integer(source, slots, store) do
      value when is_integer(value) -> {:registers, store, put_elem(slots, index, value)}
      :fallback -> assign_local(index, source, slots, store, branch)
    end
  end

  # Map get fast-path
  def execute(
        {:map_get_into, index, map, key} = operation,
        slots,
        store,
        _branch,
        _pending
      ) do
    map = Operand.container(map, slots, store)
    key = Operand.resolve(key, slots, store)

    if is_map(map) and not is_struct(map) and ground?(key),
      do: read_into(map, key, index, slots, store),
      else: fallback(operation, index, slots)
  end

  # Slot get fast path
  def execute(
        {:slot_get_into, index, object, key, _storage} = operation,
        slots,
        store,
        _branch,
        _pending
      ) do
    object = Operand.container(object, slots, store)
    key = Operand.resolve(key, slots, store)

    if is_map(object) and not AL.Var.var?(key),
      do: read_into(object, key, index, slots, store),
      else: fallback(operation, index, slots)
  end

  # Map put fast-path
  def execute(
        {:map_put_into, index, map, key, value},
        slots,
        store,
        _branch,
        _pending
      ) do
    case updated_map(map, key, value, slots, store) do
      {:ok, updated} -> {:registers, store, put_elem(slots, index, updated)}
      :error -> nil
    end
  end

  def execute(
        {:primitive_into, index, name, position, input} = operation,
        slots,
        store,
        _branch,
        _pending
      ) do
    destination = elem(slots, index)

    if destination == nil or
         (AL.Var.var?(destination) and destination != {:"$var", "_"} and
            not Map.has_key?(store, destination)) do
      input = AL.JAM.IR.Access.resolve(:primitive, name, input, slots, store)

      case AL.JAM.Primitive.output(name, position, input, store) do
        {:ok, value} -> {:registers, store, put_elem(slots, index, value)}
        :fallback -> fallback(operation, index, slots)
      end
    else
      fallback(operation, index, slots)
    end
  end

  def execute({:constraint, operation, arguments}, slots, store, branch, _pending) do
    arguments = Enum.map(arguments, &Operand.resolve(&1, slots, store))
    result = AL.JAM.Constraint.execute(operation, arguments, store, branch)

    case {operation, arguments, result} do
      {:in_domain, [var, values], nil} ->
        if AL.Var.var?(var), do: nil, else: {:diagnostic, {:domain_violated, var, values}}

      _ ->
        result
    end
  end

  def execute({:label, site, term}, slots, store, branch, _pending) do
    case AL.JAM.Label.plan(Operand.resolve(term, slots, store), store, branch) do
      :done ->
        store

      :unconstrained ->
        {:diagnostic, {:label_unconstrained, Operand.read(term, slots)}}

      {:alternatives, plans} ->
        {:alternatives,
         Enum.map(plans, fn {next_store, goals} ->
           {next_code, next_slots} = AL.JAM.IR.Assembler.compile(goals)
           {next_store, next_code, next_slots}
         end)}

      {:send, receiver, selector, arguments} ->
        instruction =
          {:send, site, {:constant, receiver}, {:constant, selector}, {:constant, arguments}}

        {:continue, store, {instruction}}
    end
  end

  def execute({:relation, operation, arguments}, slots, store, branch, _pending) do
    arguments = Enum.map(arguments, &Operand.resolve(&1, slots, store))

    case AL.JAM.Relation.execute(operation, arguments, store, branch) do
      {:ok, store} ->
        store

      {:goals, next_store, []} ->
        next_store

      {:goals, next_store, goals} ->
        {code, values} = AL.JAM.IR.Assembler.compile(goals)
        {:continue, next_store, code, values}

      {:stores, stores} ->
        {:stores, Enum.reject(stores, &is_nil/1)}
    end
  end

  def execute({:primitive, operation, arguments}, slots, store, branch, pending) do
    arguments = AL.JAM.Primitive.arguments(operation, arguments, slots, store)

    case AL.JAM.Primitive.execute(operation, arguments, store, branch, pending) do
      {:ok, store} -> store
      :fail -> nil
      {:suspend, variables} -> {:park, variables}
    end
  end

  def execute({:ground, term}, slots, store, _branch, _pending),
    do: if(ground?(Operand.resolve(term, slots, store)), do: store, else: nil)

  def execute({:is_var, term}, slots, store, _branch, _pending),
    do: if(AL.Var.var?(Operand.shallow(term, slots, store)), do: store, else: nil)

  def execute({:map_get, map, key, value}, slots, store, branch, _pending) do
    map = Operand.container(map, slots, store)
    key = Operand.resolve(key, slots, store)

    cond do
      AL.Var.var?(map) and ground?(key) ->
        AL.Var.add_key(store, map, key, Operand.resolve(value, slots, store), branch)

      AL.Var.var?(map) ->
        {:park, [map]}

      not is_map(map) or is_struct(map) ->
        nil

      ground?(key) ->
        case Map.fetch(map, key) do
          {:ok, found} ->
            AL.Var.unify(Operand.read(value, slots), AL.Var.subst(found, store), store, branch)

          :error ->
            nil
        end

      true ->
        enumerate_map(
          AL.Var.subst(map, store),
          key,
          Operand.resolve(value, slots, store),
          store,
          branch
        )
    end
  end

  def execute({:unify_structural, left, right}, slots, store, branch, _pending) do
    AL.Var.unify(
      Operand.resolve(left, slots, store),
      Operand.resolve(right, slots, store),
      store,
      branch
    )
  end

  def execute({:map_put, map, key, value, result}, slots, store, branch, _pending) do
    case updated_map(map, key, value, slots, store) do
      {:ok, updated} ->
        AL.Var.unify(Operand.resolve(result, slots, store), updated, store, branch)

      :error ->
        nil
    end
  end

  def execute(
        {:slot_get, object_operand, key_operand, value, storage},
        slots,
        store,
        branch,
        pending
      ) do
    object = Operand.container(object_operand, slots, store)
    key = Operand.resolve(key_operand, slots, store)

    cond do
      not is_map(object) ->
        execute(
          {:relation, :slot, [object_operand, key_operand, value, storage]},
          slots,
          store,
          branch,
          pending
        )

      AL.Var.var?(key) ->
        enumerate_map(
          Map.to_list(AL.Var.subst(object, store)),
          key,
          Operand.resolve(value, slots, store),
          store,
          branch
        )

      true ->
        case Map.fetch(object, key) do
          {:ok, found} ->
            AL.Var.unify(
              Operand.resolve(value, slots, store),
              AL.Var.subst(found, store),
              store,
              branch
            )

          :error ->
            nil
        end
    end
  end

  defp updated_map(map, key, value, slots, store) do
    map = Operand.resolve(map, slots, store)

    if is_map(map) and not is_struct(map),
      do:
        {:ok,
         Map.put(map, Operand.resolve(key, slots, store), Operand.resolve(value, slots, store))},
      else: :error
  end

  defp read_into(map, key, index, slots, store) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        case AL.Var.subst(value, store) do
          {:"$var", "_"} -> {:registers, store, materialize_local(slots, index)}
          resolved -> {:registers, store, put_elem(slots, index, resolved)}
        end

      :error ->
        nil
    end
  end

  defp enumerate_map(map, key, value, store, branch) do
    stores = map |> Enum.map(&AL.Var.unify({key, value}, &1, store, branch)) |> Enum.filter(& &1)
    {:stores, stores}
  end

  defp ground?(term), do: MapSet.size(AL.Var.find_vars(term)) == 0
end
