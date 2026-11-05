defmodule AL.JAM.Collection.Cursor do
  @enforce_keys [:parent, :choices, :count]
  defstruct [:parent, :choices, :count, :trace]

  @type t :: %__MODULE__{
          parent: AL.JAM.Frame.t(),
          choices: [AL.JAM.State.stack_entry()],
          count: pos_integer(),
          trace: AL.Trace.t() | nil
        }
end

defmodule AL.JAM.Collection do
  alias AL.JAM.{Frame, Operand}

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

  def collection_continuation(
        %Frame{
          code: code,
          pc: pc,
          slots: slots,
          store: store
        } = snapshot,
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

    next = %Frame{snapshot | pc: pc + 1, store: nil}

    case result do
      {:registers, next_store, next_slots} -> {%Frame{next | slots: next_slots}, next_store}
      next_store -> {next, next_store}
    end
  end
end
