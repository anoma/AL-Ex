defmodule AL.Events do
  @moduledoc """
  I am the event-sourcing process for AL. I manage the event log (stored in ETS) and provide the entrypoint for event hydration. System time here refers to a monotonic counter.
  """
  use GenServer
  use TypedStruct
  require Logger

  typedstruct enforce: true do
    field(:event, reference())
    field(:meta, reference())
  end

  @type event_op() :: :set_class | :set_super | :set_method | :set_oapply | :set_slots

  @type event() ::
          {:set_class, {AL.Var.t(), AL.Var.t()}}
          | {:set_super, {AL.Var.t(), AL.Var.t()}}
          | {:set_method, {AL.Var.t(), AL.Var.t(), AL.Var.t()}}
          | {:set_oapply, {AL.Var.t(), AL.Var.t(), [AL.goal()]}}
          | {:set_slots, {AL.Var.t(), AL.Var.t()}}

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  @doc """
  Initialise the event log, or re-use the one on disc.
  """
  def init(_opts) do
    :ok = Application.put_env(:mnesia, :dir, ~c".mnesiastore/")

    case :mnesia.create_schema([node()]) do
      :ok -> :ok
      {:error, {_, {:already_exists, _}}} -> :ok
    end

    with :ok <- :mnesia.start() do
      case :mnesia.create_table(:event,
             attributes: [:key, :event],
             type: :ordered_set,
             disc_copies: [node()]
           ) do
        {:atomic, :ok} -> :event
        {:aborted, {:already_exists, _}} -> :event
      end

      case :mnesia.create_table(:meta,
             attributes: [:key, :value],
             type: :set,
             disc_copies: [node()]
           ) do
        {:atomic, :ok} -> :meta
        {:aborted, {:already_exists, _}} -> :meta
      end

      :mnesia.wait_for_tables([:events, :meta], 5_000)

      # Do setup

      case :mnesia.dirty_read(:meta, :system_time) do
        [] -> :mnesia.dirty_write({:meta, :system_time, 0})
        [{_, :system_time, _system_time}] -> true
      end
      
      {:ok,
       %__MODULE__{
         event: :event,
         meta: :meta
       }}
    else
      {:error, :failed_to_create_schema, _error} ->
        {:error, :failed_to_create_schema}
    end
  end

  @doc """
  Read current system time
  """
  @spec system_time() :: non_neg_integer()
  def system_time() do
    GenServer.call(__MODULE__, :read_system_time)
  end

  @doc """
  Read an event at time t
  """
  @spec event(non_neg_integer()) :: event() | :absent
  def event(t) do
    GenServer.call(__MODULE__, {:read_event, t})
  end

  @doc """
  Read all events since time t
  """
  @spec events_since(non_neg_integer()) :: [{:event, {non_neg_integer(), non_neg_integer()}, event()}]
  def events_since(t) do
    GenServer.call(__MODULE__, {:events_since, t})
  end

  @doc """
  Write an event that says a class of an object was set
  """
  @spec set_class(non_neg_integer(), AL.Var.t(), AL.Var.t()) :: :ok
  def set_class(tx_id, object, class) do
    write_event(tx_id, {:set_class, {object, class}})
  end

  @doc """
  Write an event that says a superclass of an object was set
  """
  @spec set_super(non_neg_integer(), AL.Var.t(), AL.Var.t()) :: :ok
  def set_super(tx_id, object, super) do
    write_event(tx_id, {:set_super, {object, super}})
  end

  @doc """
  Write an event that says a method was set for an object
  """
  @spec set_method(non_neg_integer(), AL.Var.t(), AL.Var.t(), AL.Var.t()) :: :ok
  def set_method(tx_id, object, method_name, method_id) do
    write_event(tx_id, {:set_method, {object, method_name, method_id}})
  end

  @doc """
  Write an event that says the object was given a run method
  """
  @spec set_oapply(non_neg_integer(), AL.Var.t(), AL.Var.t(), [AL.goal()]) :: :ok
  def set_oapply(tx_id, object, head, body) do
    write_event(tx_id, {:set_oapply, {object, head, body}})
  end

  @doc """
  Write an event that says slots were set for an object
  """
  @spec set_slots(non_neg_integer(), AL.Var.t(), AL.Var.t()) :: :ok
  def set_slots(tx_id, object, slots) do
    write_event(tx_id, {:set_slots, {object, slots}})
  end

  @spec write_event(non_neg_integer(), event()) :: :ok
  def write_event(tx_id, e) do
    t = :mnesia.dirty_update_counter(:meta, :system_time, 1)
    
    :mnesia.write({:event, {tx_id, (t - 1)}, e})
  end

  
  @impl true
  def handle_call(:read_system_time, _from, state) do
    case :mnesia.dirty_read(state.meta, :system_time) do
      [{_, :system_time, v}] -> {:reply, v, state}
      [] -> {:reply, :absent, state}
    end
  end

  @impl true
  def handle_call({:read_event, tx_id, t}, _from, state) do
    case :mnesia.dirty_read(state.event, {tx_id, t}) do
      [{_, {^tx_id, ^t}, e}] -> {:reply, e, state}
      [] -> {:reply, :absent, state}
    end
  end

  @impl true
  def handle_call({:events_since, t}, _from, state) do
    {:atomic, res} =
      :mnesia.transaction(fn ->
        :mnesia.select(state.event, [
          {{:event, {:"$1", :"$2"}, :"$3"}, [{:>=, :"$1", t}], [:"$_"]}
        ])
      end)

    {:reply, res, state}
  end

  @impl true
  def handle_call({:events_for_transaction, tx_id}, _from, state) do
    {:atomic, res} =
      :mnesia.transaction(fn ->
        :mnesia.select(state.event, [
          {{:event, {tx_id, :"$1"}, :"$2"}, [], [:"$_"]}
        ])
      end)

    {:reply, res, state}
  end
end
