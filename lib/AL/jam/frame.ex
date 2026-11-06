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
          | {:cut_scope, reference(), descriptor()}
          # Specialised
          | {:guarded_region, term(), term(), non_neg_integer(), non_neg_integer()}
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
  end

  def entry(id, {code, slots, store, _variants, _forwarded, head}, returns, pending \\ %{}) do
    frame = frame_descriptor(id, {head, slots})

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
        pending: pending
      }
    else
      %__MODULE__{
        descriptor: frame,
        code: code,
        slots: slots,
        returns: returns,
        store: store,
        pending: pending
      }
    end
  end

  def frame_descriptor({:provider, method, cursor}, head), do: {:provider, method, cursor, head}

  def frame_descriptor(method, head) when is_atom(method) and method != :call,
    do: {:provider, method, nil, head}

  def frame_descriptor(id, _head), do: id

  def region_return(
        code,
        callee_slots,
        {_, _, outputs},
        destinations,
        {id, caller_code, pc, caller_slots} = caller,
        returns,
        store
      ) do
    transfer =
      Enum.find_value(destinations, fn destination ->
        variable = elem(caller_slots, destination)

        if AL.Var.var?(variable) and variable != {:"$var", "_"} and
             not Map.has_key?(store, variable) do
          Enum.find_value(outputs, fn {source, specialized} ->
            if elem(callee_slots, source) == variable, do: {source, destination, specialized}
          end)
        end
      end)

    case transfer do
      {source, destination, specialized} ->
        {specialized,
         [{:return_to, id, caller_code, pc, caller_slots, [{source, destination}]} | returns]}

      nil ->
        {code, keep_return(caller, returns)}
    end
  end

  def returning_entry(
        _id,
        {_code, _callee_slots, store, _variants, [_ | _] = forwarded, _head},
        {caller_id, caller_code, caller_pc, caller_slots},
        returns,
        _destinations,
        _store,
        _branch
      ) do
    slots =
      Enum.reduce(forwarded, caller_slots, fn {destination, value}, slots ->
        put_elem(slots, destination, value)
      end)

    %__MODULE__{
      descriptor: caller_id,
      code: caller_code,
      pc: caller_pc,
      slots: slots,
      returns: returns,
      store: store
    }
  end

  def returning_entry(
        id,
        {code, callee_slots, store, variants, [], head},
        {caller_id, caller_code, caller_pc, caller_slots} = caller,
        returns,
        [_ | _] = destinations,
        store,
        _branch
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
                {:local, index} -> {:local, index, operation}
                {:send_local, destinations} -> {:send_local, operation, destinations}
                {:destination, index} -> put_elem(operation, 2, {:destination, index})
              end

            put_elem(code, pc, specialized)
          end)

        frame =
          {:return_to, caller_id, caller_code, caller_pc, caller_slots, [{source, destination}]}

        entry(id, {specialized, callee_slots, store, variants, [], head}, [frame | returns])

      nil ->
        entry(id, {code, callee_slots, store, variants, [], head}, keep_return(caller, returns))
    end
  end

  def returning_entry(id, selected, caller, returns, _destinations, _store, _branch),
    do: entry(id, selected, keep_return(caller, returns))

  def keep_return(caller, [{:return_to, _, _, _, _, [_ | _]} | _] = returns),
    do: [caller_return(caller) | returns]

  def keep_return({id, code, pc, _slots} = caller, returns) when pc == tuple_size(code) do
    if root_progress(id, pc) != nil, do: [caller_return(caller) | returns], else: returns
  end

  def keep_return(caller, returns), do: [caller_return(caller) | returns]

  defp caller_return({id, code, pc, slots}), do: {:return_to, id, code, pc, slots, []}

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
            case Instruction.execute({:local, index, operation}, callee_slots, store, branch) do
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

  def send_dnu(id, code, pc, slots, returns, store, pending, object, method, args) do
    goal = %Goal.Send{
      object: AL.Var.subst(object, store),
      method: :does_not_understand,
      args: [method, Operand.resolve(args, slots, store)]
    }

    {next_code, next_slots} = AL.JAM.IR.Assembler.compile([goal])

    %__MODULE__{
      descriptor: id,
      code: next_code,
      slots: next_slots,
      returns: keep_return({id, code, pc + 1, slots}, returns),
      store: store,
      pending: pending
    }
  end

  def return_to(id, code, pc, slots, returns),
    do: keep_return({id, code, pc + 1, slots}, returns)

  @doc """
  Merge context suspensions into current frame
  """
  def import_pending(snapshot, context) do
    case Map.get(context, :suspensions, %{}) do
      suspensions when suspensions == %{} ->
        snapshot

      suspensions ->
        %{
          snapshot
          | pending:
              Map.merge(suspensions, snapshot.pending, fn _key, older, newer -> older ++ newer end)
        }
    end
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

  defp pending_returns([{:return_to, id, code, pc, caller_slots, transfers} | returns], slots) do
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

  def without_suspensions(snapshot), do: %{snapshot | pending: %{}}

  def wake_frame({id, code, slots}), do: %__MODULE__{descriptor: id, code: code, slots: slots}

  def pending(%__MODULE__{
        pending: pending
      }),
      do: pending

  def wake_goals({_id, code, slots}), do: Goals.instructions(code, 0, slots)

  def failed_goal(%__MODULE__{
        code: code,
        pc: pc,
        slots: slots
      }),
      do: Goals.instruction(elem(code, pc), slots)

  def snapshot_store(%__MODULE__{
        store: store
      }),
      do: store

  def completed_goals(%__MODULE__{
        descriptor: id,
        pc: pc,
        returns: returns
      }) do
    returns
    |> Enum.reduce(root_progress(id, pc), fn
      {:return_to, caller, _code, caller_pc, _slots, _transfers}, progress ->
        root_progress(caller, max(caller_pc - 1, 0)) || progress

      _, progress ->
        progress
    end)
    |> then(&(&1 || 0))
  end

  defp root_progress({:root, _scope}, pc), do: pc
  defp root_progress({:traced, _scope, _seq, id}, pc), do: root_progress(id, pc)
  defp root_progress({:cut_scope, _scope, id}, pc), do: root_progress(id, pc)
  defp root_progress(_id, _pc), do: nil
end
