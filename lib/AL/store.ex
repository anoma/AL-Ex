defmodule AL.Store do
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
  def interp(%Goal.SetClass{object: o, class: c}, state), do: write(state, :set_class, [o, c])

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
  defp write(state, fun, args) do
    apply(AL.Command, fun, [state.tx_id | args] ++ [state.branch])
    apply(AL.Object, fun, args ++ [state.branch])
    state
  end

  defp store_body(body) when is_list(body), do: Enum.map(body, &AL.Goal.to_stored/1)
  defp store_body(body), do: body
end
