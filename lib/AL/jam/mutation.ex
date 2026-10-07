defmodule AL.JAM.Mutation do
  alias AL.Goal

  def execute(:output, [text], state), do: %AL{state | output: [text | state.output]}

  def execute(:source_scope_enter, [capture_id, goals], state),
    do: AL.Source.enter_scope(state, capture_id, goals)

  def execute(:source_scope_exit, [capture_id], state),
    do: AL.Source.exit_scope(state, capture_id)

  def execute(:send_async, [object, method, args], state) do
    AL.Command.send_async(state.tx_id, object, method, args, state.branch)
    state
  end

  def execute(:send_elixir, [pid, message], state) do
    AL.Command.send_elixir(state.tx_id, pid, message, state.branch)
    state
  end

  def execute(:emit_effect, [effect, provider, operation, arguments], state) do
    AL.Edge.request(state.tx_id, effect, provider, operation, arguments, state.branch)
    state
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
        write(state, :set_class, [o, c])
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
    write(state, :set_slot, [o, k, v, store])
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
    write(state, :retract_slot, [o, k, store])
  end

  def goal(:send_async, [object, method, args]),
    do: %Goal.SendAsync{object: object, method: method, args: args}

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

  defp store_body(body) when is_list(body), do: Enum.map(body, &AL.Goal.to_stored/1)
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
