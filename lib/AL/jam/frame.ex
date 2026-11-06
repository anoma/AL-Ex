defmodule AL.JAM.Frame do
  use TypedStruct

  alias AL.Goal
  alias AL.JAM.{Goals, Instruction, Operand}
  @compile {:inline, project_send: 5, keep_return: 2}

  @moduledoc "A suspended JAM execution with its registers, return frames, bindings, and pending goals."

  # Top-level goals
  @type descriptor() ::
          {:root, AL.JAM.State.scope()}
          # Selected method clause
          | {:provider, term(), term(), {term(), tuple()}}
          # Inner frame
          | {:traced, AL.JAM.State.scope(), non_neg_integer() | nil, descriptor()}
          # Inner frame
          | {:cut_scope, [AL.JAM.State.stack_entry()], descriptor()}
          | {:implies_scope, [AL.JAM.State.stack_entry()] | nil, descriptor()}
          # Else
          | atom()

  typedstruct enforce: true do
    # Tagged descriptor for current code
    field(:descriptor, descriptor(), enforce: true)
    # Machine instructions for this frame
    field(:code, tuple(), enforce: true)
    # The frame's registers
    field(:slots, tuple(), enforce: true)
    # Pointer to next instruction to execute
    field(:pc, non_neg_integer(), default: 0)
    # Saved caller frames and return actions
    field(:returns, list(), default: [])
    # Bindings and constraints on this path
    field(:store, AL.Var.store() | nil, default: nil)
    # Suspended goals
    field(:pending, map(), default: %{})
    field(:definition_origin, AL.Source.DefinitionOrigin.t() | nil, default: nil)
  end

  def entry(id, {code, slots, store, _variants, _forwarded, head}, returns, caller \\ nil) do
    frame = frame_descriptor(id, {head, slots})
    pending = if caller, do: caller.pending, else: %{}
    origin = if caller, do: caller.definition_origin, else: nil

    if tuple_size(code) > 0 and is_tuple(elem(code, 0)) and elem(elem(code, 0), 0) == :cursor do
      {:cursor, index} = elem(code, 0)

      cursor =
        case id do
          {:provider, _, cursor} -> cursor
          _ -> nil
        end

      %__MODULE__{
        descriptor: frame,
        code: code,
        pc: 1,
        slots: put_elem(slots, index, cursor),
        returns: returns,
        store: store,
        pending: pending,
        definition_origin: origin
      }
    else
      %__MODULE__{
        descriptor: frame,
        code: code,
        slots: slots,
        returns: returns,
        store: store,
        pending: pending,
        definition_origin: origin
      }
    end
  end

  def frame_descriptor({:provider, method, cursor}, head), do: {:provider, method, cursor, head}

  def frame_descriptor(method, head) when is_atom(method) and method != :call,
    do: {:provider, method, nil, head}

  def frame_descriptor(id, _head), do: id

  def returning_entry(
        _id,
        {_code, _callee_slots, store, _variants, [_ | _] = forwarded, _head},
        %__MODULE__{slots: caller_slots} = caller,
        _destinations
      ) do
    slots =
      Enum.reduce(forwarded, caller_slots, fn {destination, value}, slots ->
        put_elem(slots, destination, value)
      end)

    %__MODULE__{caller | slots: slots, store: store}
  end

  def returning_entry(
        id,
        {code, callee_slots, store, variants, [], head},
        %__MODULE__{slots: caller_slots, returns: returns, store: store} = caller,
        [_ | _] = destinations
      )
      when map_size(variants) > 0 do
    transfer =
      Enum.find_value(destinations, fn destination ->
        variable = elem(caller_slots, destination)

        Enum.find_value(variants, fn {index, specialized} ->
          if elem(callee_slots, index) == variable, do: {index, destination, specialized}
        end)
      end)

    case transfer do
      {source, destination, patches} ->
        specialized =
          Enum.reduce(patches, code, fn {pc, patch}, code ->
            operation = elem(code, pc)

            specialized =
              case patch do
                {:instruction, instruction} ->
                  instruction

                {:send_local, destinations} ->
                  {:send_local, operation, destinations}

                {:destination, index} ->
                  put_elem(operation, 2, {:destination, index})
              end

            put_elem(code, pc, specialized)
          end)

        frame = caller_return(caller, [{source, destination}])

        entry(
          id,
          {specialized, callee_slots, store, variants, [], head},
          [frame | returns],
          caller
        )

      nil ->
        entry(
          id,
          {code, callee_slots, store, variants, [], head},
          keep_return(caller, returns),
          caller
        )
    end
  end

  def returning_entry(id, selected, caller, _destinations),
    do: entry(id, selected, keep_return(caller, caller.returns), caller)

  def keep_return(frame, returns), do: keep_return(frame, frame.pc, returns)

  defp keep_return(frame, pc, [{:return_to, _, _, _, _, [_ | _], _} | _] = returns),
    do: [caller_return(frame, pc, []) | returns]

  defp keep_return(%__MODULE__{descriptor: id, code: code} = frame, pc, returns)
       when pc == tuple_size(code) do
    if root_progress(id, pc) != nil, do: [caller_return(frame, pc, []) | returns], else: returns
  end

  defp keep_return(frame, pc, returns), do: [caller_return(frame, pc, []) | returns]

  defp caller_return(frame, transfers), do: caller_return(frame, frame.pc, transfers)

  defp caller_return(frame, pc, transfers),
    do:
      {:return_to, frame.descriptor, frame.code, pc, frame.slots, transfers,
       frame.definition_origin}

  def advance(%__MODULE__{} = frame), do: %{frame | pc: frame.pc + 1}

  def return_to(%__MODULE__{} = frame), do: keep_return(frame, frame.pc + 1, frame.returns)

  def suspend(%__MODULE__{} = frame, code),
    do: {frame.descriptor, code, frame.slots, frame.definition_origin}

  def wake_return({id, code, slots, origin}),
    do: {:return_to, id, code, 0, slots, [], origin}

  def transfer_registers(_callee_slots, caller_slots, []), do: caller_slots

  def transfer_registers(callee_slots, caller_slots, transfers),
    do:
      Enum.reduce(transfers, caller_slots, fn {source, destination}, slots ->
        put_elem(slots, destination, elem(callee_slots, source))
      end)

  def project_send(
        [{code, callee_slots, store, _variants, [], _head}],
        [_ | _] = destinations,
        slots,
        store,
        branch
      ) do
    case AL.JAM.Registers.projection(code) do
      {index, operation} ->
        variable = elem(callee_slots, index)

        case Enum.find(destinations, &(elem(slots, &1) == variable)) do
          nil ->
            :call

          destination ->
            case Instruction.execute(
                   Instruction.into(operation, index),
                   callee_slots,
                   store,
                   branch
                 ) do
              {:registers, next_store, next_slots} ->
                {:registers, next_store, put_elem(slots, destination, elem(next_slots, index))}

              _ ->
                :call
            end
        end

      nil ->
        :call
    end
  end

  def project_send(_selected, _destinations, _slots, _store, _branch), do: :call

  def send_dnu(%__MODULE__{slots: slots, store: store} = current, object, method, args) do
    goal = %Goal.Send{
      object: AL.Var.subst(object, store),
      method: :does_not_understand,
      args: [method, Operand.resolve(args, slots, store)]
    }

    {next_code, next_slots} = AL.JAM.IR.Assembler.compile([goal])

    %__MODULE__{current | code: next_code, pc: 0, slots: next_slots, returns: return_to(current)}
  end

  def pending_goals(%__MODULE__{
        code: code,
        pc: pc,
        slots: slots,
        returns: returns
      }) do
    Goals.instructions(code, pc, slots) ++ pending_returns(returns, slots)
  end

  defp pending_returns([], _slots), do: []
  defp pending_returns([{:trace_exit, _} | returns], slots), do: pending_returns(returns, slots)

  defp pending_returns(
         [{:return_to, id, code, pc, caller_slots, transfers, _origin} | returns],
         slots
       ) do
    slots = transfer_registers(slots, caller_slots, transfers)

    pending_goals(%__MODULE__{
      descriptor: id,
      code: code,
      pc: pc,
      slots: slots,
      returns: returns
    })
  end

  def with_store(%__MODULE__{} = frame, store), do: %{frame | store: store}

  def wake_goals({_id, code, slots, _origin}), do: Goals.instructions(code, 0, slots)

  def failed_goal(%__MODULE__{
        code: code,
        pc: pc,
        slots: slots
      }),
      do: Goals.instruction(elem(code, pc), slots)

  def completed_goals(%__MODULE__{
        descriptor: id,
        pc: pc,
        returns: returns
      }) do
    returns
    |> Enum.reduce(root_progress(id, pc), fn
      {:return_to, caller, _code, caller_pc, _slots, _transfers, _origin}, progress ->
        root_progress(caller, max(caller_pc - 1, 0)) || progress

      _, progress ->
        progress
    end)
    |> then(&(&1 || 0))
  end

  defp root_progress({:root, _scope}, pc), do: pc
  defp root_progress({:traced, _scope, _seq, id}, pc), do: root_progress(id, pc)
  defp root_progress({:cut_scope, _scope, id}, pc), do: root_progress(id, pc)
  defp root_progress({:implies_scope, _boundary, id}, pc), do: root_progress(id, pc)
  defp root_progress(_id, _pc), do: nil
end
