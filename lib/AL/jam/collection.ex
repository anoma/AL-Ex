defmodule AL.JAM.Collection.Cursor do
  @enforce_keys [:parent, :choices, :count]
  defstruct [:parent, :choices, :count, :driver]

  @type t :: %__MODULE__{
          parent: AL.JAM.Frame.t(),
          choices: list(),
          count: pos_integer(),
          driver: %{choicepoint: AL.Choicepoint.t(), trace: AL.Trace.t()} | nil
        }
end

defmodule AL.JAM.Collection do
  alias AL.JAM.{Frame, Goals, Operand}

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

  def collection_condition(%Frame{
        code: code,
        pc: pc,
        slots: slots
      }) do
    condition =
      case elem(code, pc) do
        {:collect, _, _, condition} -> condition
        {:collect_n, _, _, _, condition} -> condition
        {:negate, condition} -> condition
      end

    Goals.instructions(condition, 0, slots)
  end

  def collection_continuation(
        %Frame{
          descriptor: id,
          code: code,
          pc: pc,
          slots: slots,
          returns: returns,
          store: store,
          pending: pending
        },
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

    case result do
      {:registers, next_store, next_slots} ->
        {%Frame{
           descriptor: id,
           code: code,
           pc: pc + 1,
           slots: next_slots,
           returns: returns,
           pending: pending
         }, next_store}

      next_store ->
        {%Frame{
           descriptor: id,
           code: code,
           pc: pc + 1,
           slots: slots,
           returns: returns,
           pending: pending
         }, next_store}
    end
  end
end
