defmodule AL.JAM.Instruction do
  alias AL.JAM.Operand
  alias AL.JAM.IR.Program

  @type register() :: non_neg_integer()
  @type address() :: atom() | non_neg_integer()
  @type code() :: Program.t() | [t()] | tuple()

  @type t() ::
          :pass
          | :fail
          | :cut
          | :cut_scope
          | {:eq, left :: term(), right :: term()}
          | {:unify_structural, left :: term(), right :: term()}
          | {:dif, left :: term(), right :: term()}
          | {:compare, operator :: atom(), left :: term(), right :: term()}
          | {:ground, term()}
          | {:is_var, term()}
          | {:copy_term, original :: term(), copy :: term(), goals :: term()}
          | {:map_get, map :: term(), key :: term(), value :: term()}
          | {:map_put, map :: term(), key :: term(), value :: term(), result :: term()}
          | {:slot_get, object :: term(), key :: term(), value :: term(), storage :: term()}
          | {:primitive, name :: atom(), arguments :: [term()]}
          | {:constraint, name :: atom(), arguments :: [term()]}
          | {:relation, name :: atom(), arguments :: [term()]}
          | {:mutation, name :: atom(), arguments :: [term()]}
          | {:context, field :: atom(), result :: term()}
          | {:label, site :: term(), value :: term()}
          | {:send, site :: term(), receiver :: term(), selector :: term(), arguments :: term()}
          | {:call_method, method :: term(), arguments :: term()}
          | {:call, site :: term(), head :: term(), body :: term(), arguments :: term()}
          | {:next, cursor :: term(), receiver :: term(), arguments :: term()}
          | {:send_as, provider :: term(), cursor :: term(), arguments :: term()}
          | {:collect, template :: term(), result :: term(), condition :: code()}
          | {:collect_n, count :: term(), template :: term(), result :: term(),
             condition :: code()}
          | {:forall, captures :: term(), condition :: code(), head_slots :: [register()] | nil,
             body :: Program.t() | {code(), term()}}
          | {:negate, condition :: code()}
          | {:freeze, variable :: term(), body :: code()}
          | {:source_scope, capture_id :: term(), source :: term(), body :: code()}
          | {:branch, left :: code(), right :: code()}
          | {:condition, condition :: code(), otherwise :: code()}
          | {:commit, then :: code()}
          | {:move, destination :: register(), source :: term()}
          | {:jump, target :: address(), transfers :: [{register(), term()}]}
          | {:get_cons, source :: term(), head :: register(), tail :: register(),
             failure :: address()}
          | {:try, alternative :: address(), live :: [register()]}
          | {:numeric_tests, value :: term(), tests :: [{atom(), number()}], fallback :: code()}
          | {:integer_arithmetic, operator :: :+ | :- | :*, destination :: register(),
             left :: term(), right :: term(), fallback :: t()}
          | {:local, destination :: register(), instruction :: t()}
          | {:send_local, instruction :: t(), destinations :: [register()]}

  def operands({family, _name, args})
      when family in [:primitive, :constraint, :relation, :mutation],
      do: args

  def operands({:call_method, {:method_identity, _, _}, args}), do: [args]

  def operands(instruction),
    do: Enum.map(operand_positions(instruction), &elem(instruction, &1))

  def map_operands({family, name, args}, fun)
      when family in [:primitive, :constraint, :relation, :mutation],
      do: {family, name, Enum.map(args, fun)}

  def map_operands({:call_method, {:method_identity, _, _} = method, args}, fun),
    do: {:call_method, method, fun.(args)}

  def map_operands(instruction, fun),
    do:
      Enum.reduce(operand_positions(instruction), instruction, fn index, result ->
        put_elem(result, index, fun.(elem(instruction, index)))
      end)

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
      {:forall, _, _, _, _} -> []
      {:negate, _} -> []
      {:freeze, _, _} -> [1]
      {:source_scope, _, _, _} -> [1, 2]
      {op, _} when op in [:ground, :is_var] -> [1]
      {op, _, _} when op in [:eq, :dif, :unify_structural, :call_method] -> [1, 2]
      {op, _, _, _} when op in [:map_get, :copy_term] -> [1, 2, 3]
      {op, _, _, _, _} when op in [:map_put, :slot_get] -> [1, 2, 3, 4]
    end
  end

  def map_values({:branch, left, right}, fun),
    do: {:branch, Enum.map(left, &map_values(&1, fun)), Enum.map(right, &map_values(&1, fun))}

  def map_values({:numeric_tests, value, tests, fallback}, fun),
    do: {:numeric_tests, AL.Term.map(value, fun), tests, Enum.map(fallback, &map_values(&1, fun))}

  def map_values(instruction, fun) do
    instruction
    |> map_operands(&AL.Term.map(&1, fun))
    |> map_regions(&Program.map_values(&1, fun))
  end

  def variables({:numeric_tests, value, _tests, fallback}),
    do: Enum.reduce(fallback, AL.Var.find_vars(value), &MapSet.union(variables(&1), &2))

  def variables(instruction) do
    Enum.reduce(regions(instruction), AL.Var.find_vars(operands(instruction)), fn {_, body},
                                                                                  vars ->
      MapSet.union(vars, Program.variables(body))
    end)
  end

  def regions({:collect, _, _, condition}), do: [condition: condition]
  def regions({:collect_n, _, _, _, condition}), do: [condition: condition]
  def regions({:forall, _, condition, _, body}), do: [condition: condition, body: body]
  def regions({:negate, condition}), do: [condition: condition]
  def regions({:freeze, _, goals}), do: [goals: goals]
  def regions({:source_scope, _, _, body}), do: [body: body]
  def regions(_), do: []

  defp map_regions({:collect, template, result, condition}, fun),
    do: {:collect, template, result, fun.(condition)}

  defp map_regions({:collect_n, count, template, result, condition}, fun),
    do: {:collect_n, count, template, result, fun.(condition)}

  defp map_regions({:forall, captures, condition, head, body}, fun),
    do: {:forall, captures, fun.(condition), head, fun.(body)}

  defp map_regions({:negate, condition}, fun), do: {:negate, fun.(condition)}
  defp map_regions({:freeze, var, goals}, fun), do: {:freeze, var, fun.(goals)}

  defp map_regions({:source_scope, id, source, body}, fun),
    do: {:source_scope, id, source, fun.(body)}

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
             :map_pairs,
             :block_goals
           ] ->
        true

      {op, _} when op in [:ground, :is_var] ->
        true

      {op, _, _} when op in [:eq, :dif, :unify_structural] ->
        true

      {op, _, _, _} when op in [:copy_term, :compare, :map_get] ->
        true

      {op, _, _, _, _} when op in [:slot_get, :map_put] ->
        true

      _ ->
        false
    end
  end

  def effects(:pass), do: :pure
  def effects({op, _, _}) when op in [:eq, :dif, :unify_structural], do: :binding
  def effects({:mutation, _, _}), do: :write
  def effects({:relation, _, _}), do: :read_and_bind
  def effects(:cut), do: :control
  def effects({:next, _, _, _}), do: :control
  def effects(instruction), do: if(scoped?(instruction), do: :scoped, else: :unknown)

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

  defp primitive_fallback(operation, slots, store, branch) do
    case execute(operation, slots, store, branch) do
      {:park, _variables} -> {:continue, store, {operation}}
      result -> result
    end
  end

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

  def execute({:integer_arithmetic, op, destination, a, b, fallback}, slots, store, branch) do
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
      execute(fallback, slots, store, branch)
    end
  end

  def execute({:local, index, {:unify_structural, left, right}}, slots, store, _branch) do
    source = if left == {:register, index}, do: right, else: left
    {:registers, store, put_elem(slots, index, Operand.resolve(source, slots, store))}
  end

  def execute({:local, index, {:eq, left, right}}, slots, store, branch) do
    source = if left == {:register, index}, do: right, else: left

    case AL.JAM.Arithmetic.integer(source, slots, store) do
      value when is_integer(value) -> {:registers, store, put_elem(slots, index, value)}
      :fallback -> assign_local(index, source, slots, store, branch)
    end
  end

  def execute({:local, index, {:map_get, map, key, _result} = operation}, slots, store, branch) do
    map = Operand.container(map, slots, store)
    key = Operand.resolve(key, slots, store)

    if is_map(map) and not is_struct(map) and ground?(key),
      do: read_local(map, key, index, slots, store),
      else: execute(operation, slots, store, branch)
  end

  def execute(
        {:local, index, {:slot_get, object, key, _result, _storage} = operation},
        slots,
        store,
        branch
      ) do
    object = Operand.container(object, slots, store)
    key = Operand.resolve(key, slots, store)

    if is_map(object) and not AL.Var.var?(key),
      do: read_local(object, key, index, slots, store),
      else: execute(operation, slots, store, branch)
  end

  def execute({:local, index, {:map_put, map, key, value, _result}}, slots, store, _branch) do
    map = Operand.resolve(map, slots, store)

    if is_map(map) and not is_struct(map) do
      value =
        Map.put(map, Operand.resolve(key, slots, store), Operand.resolve(value, slots, store))

      {:registers, store, put_elem(slots, index, value)}
    else
      nil
    end
  end

  def execute({:local, index, {:primitive, name, operands} = operation}, slots, store, branch) do
    destination = elem(slots, index)

    if AL.Var.var?(destination) and destination != {:"$var", "_"} and
         not Map.has_key?(store, destination) do
      position = Enum.find_index(operands, &(&1 == {:register, index}))
      arguments = AL.JAM.Primitive.arguments(name, operands, slots, store)

      case AL.JAM.Primitive.output(name, position, arguments, store) do
        {:ok, value} -> {:registers, store, put_elem(slots, index, value)}
        :fallback -> primitive_fallback(operation, slots, store, branch)
      end
    else
      primitive_fallback(operation, slots, store, branch)
    end
  end

  def execute({:constraint, operation, arguments}, slots, store, branch) do
    arguments = Enum.map(arguments, &Operand.resolve(&1, slots, store))
    result = AL.JAM.Constraint.execute(operation, arguments, store, branch)

    case {operation, arguments, result} do
      {:in_domain, [var, values], nil} ->
        if AL.Var.var?(var), do: nil, else: {:diagnostic, {:domain_violated, var, values}}

      _ ->
        result
    end
  end

  def execute({:label, site, term}, slots, store, branch) do
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

  def execute({:relation, operation, arguments}, slots, store, branch) do
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

  def execute({:primitive, operation, arguments}, slots, store, branch) do
    arguments = AL.JAM.Primitive.arguments(operation, arguments, slots, store)

    case AL.JAM.Primitive.execute(operation, arguments, store, branch) do
      {:ok, store} -> store
      :fail -> nil
      {:suspend, variables} -> {:park, variables}
    end
  end

  def execute({:dif, a, b}, slots, store, branch),
    do:
      AL.JAM.Unification.different(
        AL.JAM.IR.Access.resolve(:direct, :dif, a, slots, store),
        AL.JAM.IR.Access.resolve(:direct, :dif, b, slots, store),
        store,
        branch
      )

  def execute({:compare, op, a, b}, slots, store, branch),
    do:
      AL.Var.Bounds.compare_value(
        store,
        op,
        Operand.resolve(a, slots, store),
        Operand.resolve(b, slots, store),
        branch
      )

  def execute({:ground, term}, slots, store, _branch),
    do: if(ground?(Operand.resolve(term, slots, store)), do: store, else: nil)

  def execute({:is_var, term}, slots, store, _branch),
    do: if(AL.Var.var?(Operand.shallow(term, slots, store)), do: store, else: nil)

  def execute({:map_get, map, key, value}, slots, store, branch) do
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

  def execute({:unify_structural, left, right}, slots, store, branch) do
    AL.Var.unify(
      Operand.resolve(left, slots, store),
      Operand.resolve(right, slots, store),
      store,
      branch
    )
  end

  def execute({:map_put, map, key, value, result}, slots, store, branch) do
    map = Operand.resolve(map, slots, store)

    if is_map(map) and not is_struct(map) do
      key = Operand.resolve(key, slots, store)
      value = Operand.resolve(value, slots, store)
      result = Operand.resolve(result, slots, store)
      AL.Var.unify(result, Map.put(map, key, value), store, branch)
    else
      nil
    end
  end

  def execute({:slot_get, object_operand, key_operand, value, storage}, slots, store, branch) do
    object = Operand.container(object_operand, slots, store)
    key = Operand.resolve(key_operand, slots, store)

    cond do
      not is_map(object) ->
        execute(
          {:relation, :slot, [object_operand, key_operand, value, storage]},
          slots,
          store,
          branch
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

  defp read_local(map, key, index, slots, store) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        case AL.Var.subst(value, store) do
          {:"$var", "_"} -> {:registers, store, slots}
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
