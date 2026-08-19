defmodule AL.Interp.Store do
  @moduledoc """
  I apply object-mutation goals — `SetClass`/`SetSuper`/`SetMethod`/`SetOapply`/
  `SetSlots` and their five `Retract*` counterparts — writing both the durable
  command log (`AL.Command`) and the in-memory projection (`AL.Object`) for
  each. Every one of these goals is a no-op when `object` is already a live
  map (an ephemeral instance, not a durable atom) — ephemeral objects carry no
  command-log identity at all (see `AL.ex`'s "Object creation is three-phase"
  note), so there is nothing to write.
  """

  alias AL.Goal

  def interp(%Goal.SetClass{object: object}, state) when is_map(object), do: state

  # Durably classifying an atom into a `super: :value` class is only a
  # conflict when the class also has a discriminating literal clause the
  # atom already satisfies (`value_member?/3` — the same check `isa?/3`
  # uses, deliberately excluding bare-variable self patterns) — that's the
  # one case where the durable leg and the generative leg would each
  # separately prove the same fact, so `findall` reports it twice. A durable
  # instance of a value class whose clauses never specify a literal (e.g.
  # one that just leaves `self` open) is a different, legal situation and
  # must not be rejected.
  def interp(%Goal.SetClass{object: o, class: c}, state) do
    existing = direct_classes(o, state.branch)

    cond do
      generative_value_class?(c, state.branch) and AL.Dispatch.value_member?(o, c, state.branch) ->
        raise "cannot durably classify #{inspect(o)} as #{inspect(c)}: #{inspect(o)} already " <>
                "matches one of #{inspect(c)}'s own literal clauses, so it's reachable both as a " <>
                "durable object and as a generative candidate for the same fact -- findall would " <>
                "report it twice. Use in_domain/2 or a map-wrapped value instead."

      # Exactly one direct class per durably-classified atom -- inheritance
      # (vm_set_super) stays a free-form DAG, unrestricted; this only
      # constrains an object's own class row, not its ancestry.
      Enum.any?(existing, &(&1 != c)) ->
        raise "cannot durably classify #{inspect(o)} as #{inspect(c)}: it already has a " <>
                "different direct class (#{inspect(existing)}). vm_retract_class it first if " <>
                "you mean to reclassify -- a durable object has exactly one direct class."

      true ->
        write(state, :set_class, [o, c])
    end
  end

  # Narrowly-scoped validation (not a general primitive) -- called only from
  # :defmethod's own accretion body. A super: :value class's clause binding
  # self to a bare atom is the one shape that's structurally indistinguishable
  # from durable identity, so it's the one case a class's own literal clause
  # could conflict with a later durable classification of the same atom.
  def interp(%Goal.AssertValidClauseSelf{class: class, head: head}, state) do
    store = state.active_choicepoint.store
    class_ground = AL.Var.subst(class, store)

    case AL.Var.subst(head, store) do
      [self_pattern | _] ->
        if generative_value_class?(class_ground, state.branch) and is_atom(self_pattern) and
             not AL.Var.var?(self_pattern) do
          raise "cannot define #{inspect(class_ground)}'s clause with a bare atom self-pattern " <>
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

  def interp(%Goal.SetSuper{object: object}, state) when is_map(object), do: state
  def interp(%Goal.SetSuper{object: o, super: s}, state), do: write(state, :set_super, [o, s])

  def interp(%Goal.SetMethod{object: object}, state) when is_map(object), do: state

  def interp(%Goal.SetMethod{object: o, name: n, id: id}, state),
    do: write(state, :set_method, [o, n, id])

  def interp(%Goal.SetOapply{object: object}, state) when is_map(object), do: state

  def interp(%Goal.SetOapply{object: o, seq: seq_pattern, head: h, body: b}, state) do
    seq =
      case seq_pattern do
        :next -> AL.Object.next_oapply_seq(o, state.branch)
        given -> given
      end

    write(state, :set_oapply, [o, seq, h, store_body(b)])
  end

  def interp(%Goal.SetSlots{object: object}, state) when is_map(object), do: state
  def interp(%Goal.SetSlots{object: o, slots: s}, state), do: write(state, :set_slots, [o, s])

  def interp(%Goal.RetractClass{object: object}, state) when is_map(object), do: state

  def interp(%Goal.RetractClass{object: o, class: c}, state),
    do: write(state, :retract_class, [o, c])

  def interp(%Goal.RetractSuper{object: object}, state) when is_map(object), do: state

  def interp(%Goal.RetractSuper{object: o, super: s}, state),
    do: write(state, :retract_super, [o, s])

  def interp(%Goal.RetractMethod{object: object}, state) when is_map(object), do: state

  def interp(%Goal.RetractMethod{object: o, name: n, id: id}, state),
    do: write(state, :retract_method, [o, n, id])

  def interp(%Goal.RetractOapply{object: object}, state) when is_map(object), do: state

  def interp(%Goal.RetractOapply{object: o, head: h}, state),
    do: write(state, :retract_oapply, [o, h])

  def interp(%Goal.RetractSlots{object: object}, state) when is_map(object), do: state

  def interp(%Goal.RetractSlots{object: o, slots: s}, state),
    do: write(state, :retract_slots, [o, s])

  # Every mutation is both a durable write (`AL.Command`, keyed by `tx_id`) and
  # an immediate projection update (`AL.Object`) — `fun` names the same
  # operation on both modules, since both are named identically by design (see
  # `AL.Command`/`AL.Object` docs).
  #
  # `class`/`super`/`method` additionally carry transaction-time
  # (`tx_from`/`tx_to`, see `AL.Object`'s `@relations` doc) -- `AL.Command`'s
  # write already returns the `system_time` it stamped the command with
  # (`write_command/3`), so that's threaded straight into the matching
  # `AL.Object` call as its `tx` rather than reading `system_time` fresh a
  # second time, which would race a concurrent write and disagree with what
  # the command log itself actually recorded.
  @tx_stamped [:set_class, :set_super, :set_method, :retract_class, :retract_super, :retract_method]

  defp write(state, fun, args) when fun in @tx_stamped do
    tx = apply(AL.Command, fun, [state.tx_id | args] ++ [state.branch])
    apply(AL.Object, fun, args ++ [tx, state.branch])
    state
  end

  defp write(state, fun, args) do
    apply(AL.Command, fun, [state.tx_id | args] ++ [state.branch])
    apply(AL.Object, fun, args ++ [state.branch])
    state
  end

  defp store_body(body) when is_list(body), do: Enum.map(body, &AL.Goal.to_stored/1)
  defp store_body(body), do: body

  defp generative_value_class?(class, branch),
    do: AL.Object.scan_super(class, :value, branch) != []

  defp direct_classes(o, branch) do
    scope = AL.fresh_scope()

    for {:class, _o, _seq, class} <-
          AL.Object.scan_class(o, AL.Var.var("direct_class_check_#{scope}"), branch),
        do: class
  end
end
