defmodule AL.JAM.Mutation do
  require AL.Block
  alias AL.Goal

  def execute(:source_scope_enter, [capture_id, goals], state),
    do: AL.Source.enter_scope(state, capture_id, goals)

  def execute(:source_scope_exit, [capture_id], state),
    do: AL.Source.exit_scope(state, capture_id)

  def execute(:await, [target], state) do
    unless is_atom(target) and AL.Dispatch.instance_of?(target, :completion, state.branch) do
      raise ArgumentError, "await requires a completion object, got: #{inspect(target)}"
    end

    AL.Command.await(state.tx_id, target, state.branch)
    track_work(state, :waits, target)
  end

  def execute(:send_elixir, [pid, message], state) do
    AL.Command.send_elixir(state.tx_id, pid, message, state.branch)
    track_work(state, :deliveries, {:send, pid, message})
  end

  def execute(:emit_effect, [effect, provider, operation, arguments], state) do
    AL.Edge.request(state.tx_id, effect, provider, operation, arguments, state.branch)
    track_work(state, :deliveries, {:effect, effect, provider, operation, arguments})
  end

  def execute(:set_class, [object, _], state) when is_map(object), do: state

  def execute(:set_class, [o, c], state) do
    existing = direct_classes(o, state.branch)

    cond do
      generative_value_class?(c, state.branch) and AL.Dispatch.value_member?(o, c, state.branch) ->
        raise "cannot durably classify #{inspect(o)} as #{inspect(c)}: #{inspect(o)} already " <>
                "matches one of #{inspect(c)}'s own literal clauses, so it's reachable both as a " <>
                "durable object and as a generative candidate for the same fact -- findall would " <>
                "report it twice. Use in_domain/2 or a map-wrapped value instead."

      Enum.any?(existing, &(&1 != c)) ->
        raise "cannot durably classify #{inspect(o)} as #{inspect(c)}: it already has a " <>
                "different direct class (#{inspect(existing)}). vm_retract_class it first if " <>
                "you mean to reclassify -- a durable object has exactly one direct class."

      true ->
        state = write(state, :set_class, [o, c])
        if existing == [], do: AL.ResolutionCache.mark_new_receiver(state.branch, o)

        case c do
          :future_transaction ->
            state |> track_work(:futures, o) |> track_work(:deliveries, {:future, o})

          :effect ->
            track_work(state, :effects, o)

          _ ->
            state
        end
    end
  end

  def execute(:assert_valid_clause_self, [class, head], state) do
    case head do
      [self_pattern | _] ->
        if generative_value_class?(class, state.branch) and is_atom(self_pattern) and
             not AL.Var.var?(self_pattern) do
          raise "cannot define #{inspect(class)}'s clause with a bare atom self-pattern " <>
                  "(#{inspect(self_pattern)}) -- a super: :value class's own literal clauses " <>
                  "must bind self to a map, number, or list (or leave it open), never a bare " <>
                  "atom, since atoms are how AL represents durable identity. Use a map wrapper " <>
                  "(%{class: ..., ...}) instead."
        else
          state
        end

      _ ->
        state
    end
  end

  def execute(:set_super, [object, _], state) when is_map(object), do: state
  def execute(:set_super, [o, s], state), do: write(state, :set_super, [o, s])

  def execute(:set_method, [object, _, _], state) when is_map(object), do: state

  def execute(:set_method, [o, n, id], state),
    do: write(state, :set_method, [o, n, id])

  def execute(:set_oapply, [object, _, _, _], state) when is_map(object), do: state

  def execute(:set_oapply, [o, seq_pattern, h, b], state) do
    seq =
      case seq_pattern do
        :next -> AL.Object.next_oapply_seq(o, state.branch)
        given -> given
      end

    write(state, :set_oapply, [o, seq, h, store_body(b)])
  end

  def execute(:set_slot, [object, _, _], state) when is_map(object), do: state

  def execute(:set_slot, [o, k, v], state) do
    store = AL.Dispatch.ivar_storage(o, k, state.branch)
    state = write(state, :set_slot, [o, k, v, store])

    after_set_slot(state, o, k, v)
  end

  def execute(:slot_batch, [writes], state) do
    {state, pending} =
      Enum.reduce(writes, {state, []}, fn {object, key, value}, {state, pending} ->
        if batchable_aos_write?(object, key, value, state.branch) and
             (pending == [] or elem(hd(pending), 0) == object) do
          time = AL.Command.set_slot(state.tx_id, object, key, value, :aos, state.branch)
          state = AL.Source.anchor(state, :set_slot, [object, key, value, :aos], time)
          state = after_set_slot(state, object, key, value)
          {state, [{object, key, value, time} | pending]}
        else
          flush_aos_writes(pending, state.branch)
          {execute(:set_slot, [object, key, value], state), []}
        end
      end)

    flush_aos_writes(pending, state.branch)
    state
  end

  def execute(:retract_class, [object, _], state) when is_map(object), do: state

  def execute(:retract_class, [o, c], state),
    do: write(state, :retract_class, [o, c])

  def execute(:retract_super, [object, _], state) when is_map(object), do: state

  def execute(:retract_super, [o, s], state),
    do: write(state, :retract_super, [o, s])

  def execute(:retract_method, [object, _, _], state) when is_map(object), do: state

  def execute(:retract_method, [o, n, id], state),
    do: write(state, :retract_method, [o, n, id])

  def execute(:retract_oapply, [object, _], state) when is_map(object), do: state

  def execute(:retract_oapply, [o, h], state),
    do: write(state, :retract_oapply, [o, h])

  def execute(:retract_slot, [object, _], state) when is_map(object), do: state

  def execute(:retract_slot, [o, k], state) do
    store = AL.Dispatch.ivar_storage(o, k, state.branch)
    state = write(state, :retract_slot, [o, k, store])

    if k in [:status, :wait_transaction],
      do: track_action_slot(state, o, k, {:retracted}),
      else: state
  end

  defp after_set_slot(state, o, k, v) do
    state =
      if k in [:status, :wait_transaction],
        do: track_action_slot(state, o, k, v),
        else: state

    if k == :status and v == :completed do
      state = track_work(state, :completed_objects, o)

      if AL.Dispatch.instance_of?(o, :effect, state.branch),
        do: track_work(state, :completed_effects, o),
        else: state
    else
      state
    end
  end

  defp batchable_aos_write?(object, key, value, branch)
       when is_atom(object) and is_atom(key) and key not in [:ivars, :dispatch_strategy],
       do: storable?(object, key, value) and AL.Dispatch.ivar_storage(object, key, branch) == :aos

  defp batchable_aos_write?(_object, _key, _value, _branch), do: false

  defp flush_aos_writes([], _branch), do: :ok

  defp flush_aos_writes([{object, _, _, _} | _] = pending, branch) do
    changes =
      pending
      |> Enum.reverse()
      |> Enum.map(fn {^object, key, value, time} -> {key, value, time} end)

    AL.Object.set_aos_slot_batch(object, changes, branch)
  end

  defp storable?(object, key, value) do
    AL.Goal.validate_storable!([object, key, value, :aos])
    true
  rescue
    AL.Goal.StorableError -> false
  end

  def goal(:await, [target]), do: %Goal.Await{target: target}

  def goal(:source_scope_exit, [_capture_id]), do: %Goal.Pass{}

  def goal(:send_elixir, [pid, message]), do: %Goal.SendElixir{pid: pid, message: message}

  def goal(:emit_effect, [effect, provider, operation, arguments]),
    do: %Goal.EmitEffect{
      effect: effect,
      provider: provider,
      operation: operation,
      arguments: arguments
    }

  def goal(:set_class, [object, class]), do: %Goal.SetClass{object: object, class: class}

  def goal(:set_super, [object, super]), do: %Goal.SetSuper{object: object, super: super}

  def goal(:set_method, [object, name, id]),
    do: %Goal.SetMethod{object: object, name: name, id: id}

  def goal(:set_oapply, [object, seq, head, body]),
    do: %Goal.SetOapply{object: object, seq: seq, head: head, body: body}

  def goal(:set_slot, [object, key, value]),
    do: %Goal.SetSlot{object: object, key: key, value: value}

  def goal(:slot_batch, [[{object, key, value} | _]]),
    do: %Goal.SetSlot{object: object, key: key, value: value}

  def goal(:retract_class, [object, class]), do: %Goal.RetractClass{object: object, class: class}

  def goal(:retract_super, [object, super]), do: %Goal.RetractSuper{object: object, super: super}

  def goal(:retract_method, [object, name, id]),
    do: %Goal.RetractMethod{object: object, name: name, id: id}

  def goal(:retract_oapply, [object, head]), do: %Goal.RetractOapply{object: object, head: head}

  def goal(:retract_slot, [object, key]), do: %Goal.RetractSlot{object: object, key: key}

  def goal(:assert_valid_clause_self, [class, head]),
    do: %Goal.AssertValidClauseSelf{class: class, head: head}

  @tx_stamped [
    :set_class,
    :set_super,
    :set_method,
    :set_oapply,
    :set_slot,
    :retract_class,
    :retract_super,
    :retract_method,
    :retract_oapply,
    :retract_slot
  ]

  @identity_positions %{
    set_class: [0, 1],
    set_super: [0, 1],
    set_method: [0, 2],
    set_oapply: [0],
    set_slot: [0],
    retract_class: [0, 1],
    retract_super: [0, 1],
    retract_method: [0, 2],
    retract_oapply: [0],
    retract_slot: [0]
  }

  defp write(state, fun, args) when fun in @tx_stamped do
    :ok = validate_durable_identities!(fun, args)
    :ok = AL.Goal.validate_storable!(args)
    tx = apply(AL.Command, fun, [state.tx_id | args] ++ [state.branch])
    apply(AL.Object, fun, args ++ [tx, state.branch])
    AL.Source.anchor(state, fun, args, tx)
  end

  defp write(state, fun, args) do
    :ok = validate_durable_identities!(fun, args)
    :ok = AL.Goal.validate_storable!(args)
    apply(AL.Command, fun, [state.tx_id | args] ++ [state.branch])
    apply(AL.Object, fun, args ++ [state.branch])
    state
  end

  defp track_work(state, key, value) do
    work = AL.JAM.TransactionWork.add(state.transaction_work, key, value)
    %{state | transaction_work: work}
  end

  defp track_action_slot(state, object, key, value) do
    %{
      state
      | transaction_work:
          AL.JAM.TransactionWork.track_action_slot(
            state.transaction_work,
            object,
            key,
            value
          )
    }
  end

  defp validate_durable_identities!(operation, arguments) do
    operation
    |> then(&Map.get(@identity_positions, &1, []))
    |> Enum.each(fn position ->
      identity = Enum.at(arguments, position)

      if not (is_atom(identity) or AL.Var.var?(identity)) do
        raise ArgumentError,
              "#{operation} requires an atom durable identity at argument #{position + 1}, got: #{inspect(identity)}"
      end
    end)

    :ok
  end

  defp store_body(body) when AL.Block.is_block(body), do: store_body(Tuple.to_list(body))

  defp store_body(body) when is_list(body),
    do: body |> Goal.goals() |> Enum.map(&Goal.to_stored/1)

  defp store_body(body), do: body

  defp generative_value_class?(class, branch),
    do: AL.Object.scan_super(class, :value, branch) != []

  defp direct_classes(o, branch) do
    scope = AL.fresh_scope()

    for {:class, _o, _seq, class} <-
          AL.Object.scan_class(
            o,
            AL.Var.fresh({:"$var", "direct_class_check"}, Integer.to_string(scope)),
            branch
          ),
        do: class
  end
end
