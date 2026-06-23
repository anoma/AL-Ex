defmodule AL.Command do
  @moduledoc """
  I am the event-sourcing / command-logging module for AL. I manage the event/command log (stored in Mnesia) and provide the entrypoint for event hydration. System time here refers to a monotonic counter.
  """

  @type command_op() ::
          :set_class
          | :set_super
          | :set_method
          | :set_oapply
          | :set_slots
          | :retract_class
          | :retract_super
          | :retract_method
          | :retract_oapply
          | :retract_slots
          | :send_async
          | :send_elixir

  @type command() ::
          {:set_class, {AL.Var.t(), AL.Var.t()}}
          | {:set_super, {AL.Var.t(), AL.Var.t()}}
          | {:set_method, {AL.Var.t(), AL.Var.t(), AL.Var.t()}}
          | {:set_oapply, {AL.Var.t(), AL.Var.t(), [AL.goal()]}}
          | {:set_slots, {AL.Var.t(), AL.Var.t()}}
          | {:retract_class, {AL.Var.t(), AL.Var.t()}}
          | {:retract_super, {AL.Var.t(), AL.Var.t()}}
          | {:retract_method, {AL.Var.t(), AL.Var.t(), AL.Var.t()}}
          | {:retract_oapply, {AL.Var.t(), AL.Var.t()}}
          | {:retract_slots, {AL.Var.t(), AL.Var.t()}}
          | {:send_async, {AL.Var.t(), AL.Var.t(), AL.Var.t()}}
          | {:send_elixir, {AL.Var.t(), AL.Var.t()}}

          
  @doc """
  Initialise the event log, or re-use the one on disc.
  """
  def setup() do
    :ok = Application.put_env(:mnesia, :dir, ~c".mnesiastore/")

    case :mnesia.create_schema([node()]) do
      :ok -> :ok
      {:error, {_, {:already_exists, _}}} -> :ok
    end

    :ok = :mnesia.start()

    case :mnesia.create_table(:command,
           attributes: [:t, :tx_id, :command],
           type: :ordered_set,
           disc_copies: [node()]
         ) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
    end

    case :mnesia.create_table(:meta,
           attributes: [:key, :value],
           type: :set,
           disc_copies: [node()]
         ) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
    end

    :mnesia.wait_for_tables([:command, :meta], 5_000)

    case :mnesia.dirty_read(:meta, :system_time) do
      [] -> :mnesia.dirty_write({:meta, :system_time, 0})
      [{_, :system_time, _}] -> :ok
    end

    case :mnesia.dirty_read(:meta, :id_counter) do
      [] -> :mnesia.dirty_write({:meta, :id_counter, 0})
      [{_, :id_counter, _}] -> :ok
    end

    case :mnesia.dirty_read(:meta, :scope_counter) do
      [] -> :mnesia.dirty_write({:meta, :scope_counter, 0})
      [{_, :scope_counter, _}] -> :ok
    end
  end

  @doc """
  Read current system time of the command log. The next command will be written at this value.
  """
  @spec system_time() :: non_neg_integer()
  def system_time() do
    case :mnesia.dirty_read(:meta, :system_time) do
      [{_, :system_time, t}] -> t
      [] -> :absent
    end
  end

  @doc """
  Read a command at time t
  """
  @spec command(non_neg_integer()) :: command() | :absent
  def command(t) do
    case :mnesia.read(:command, t) do
      [{_, ^t, _tx_id, command}] -> command
      [] -> :absent
    end
  end

  @doc """
  Read all commands since time t
  """
  @spec commands_since(non_neg_integer()) :: [command()]
  def commands_since(t) do
    :mnesia.select(:command, [
      {{:command, :"$1", :"$2", :"$3"}, [{:>=, :"$1", t}], [:"$_"]}
    ])
  end

  @doc """
  Read all commands for a given transaction
  """
  def commands_for_transaction(tx_id) do
    :mnesia.select(:command, [
      {{:command, :"$1", tx_id, :"$3"}, [], [:"$_"]}
    ])
  end

  @doc """
  Write a command that says a class of an object was set
  """
  @spec set_class(non_neg_integer(), AL.Var.t(), AL.Var.t()) :: :ok
  def set_class(tx_id, object, class) do
    write_command(tx_id, {:set_class, {object, class}})
  end

  @doc """
  Write a command that says a superclass of an object was set
  """
  @spec set_super(non_neg_integer(), AL.Var.t(), AL.Var.t()) :: :ok
  def set_super(tx_id, object, super) do
    write_command(tx_id, {:set_super, {object, super}})
  end

  @doc """
  Write a command that says a method was set for an object
  """
  @spec set_method(non_neg_integer(), AL.Var.t(), AL.Var.t(), AL.Var.t()) :: :ok
  def set_method(tx_id, object, method_name, method_id) do
    write_command(tx_id, {:set_method, {object, method_name, method_id}})
  end

  @doc """
  Write a command that says the object was given a run method
  """
  @spec set_oapply(non_neg_integer(), AL.Var.t(), AL.Var.t(), [AL.goal()]) :: :ok
  def set_oapply(tx_id, object, head, body) do
    write_command(tx_id, {:set_oapply, {object, head, body}})
  end

  @doc """
  Write a command that says slots were set for an object
  """
  @spec set_slots(non_neg_integer(), AL.Var.t(), AL.Var.t()) :: :ok
  def set_slots(tx_id, object, slots) do
    write_command(tx_id, {:set_slots, {object, slots}})
  end

  @spec retract_class(non_neg_integer(), AL.Var.t(), AL.Var.t()) :: :ok
  def retract_class(tx_id, object, class) do
    write_command(tx_id, {:retract_class, {object, class}})
  end

  @spec retract_super(non_neg_integer(), AL.Var.t(), AL.Var.t()) :: :ok
  def retract_super(tx_id, object, super) do
    write_command(tx_id, {:retract_super, {object, super}})
  end

  @spec retract_method(non_neg_integer(), AL.Var.t(), AL.Var.t(), AL.Var.t()) :: :ok
  def retract_method(tx_id, object, name, id) do
    write_command(tx_id, {:retract_method, {object, name, id}})
  end

  @spec retract_oapply(non_neg_integer(), AL.Var.t(), AL.Var.t()) :: :ok
  def retract_oapply(tx_id, object, head) do
    write_command(tx_id, {:retract_oapply, {object, head}})
  end

  @spec retract_slots(non_neg_integer(), AL.Var.t(), AL.Var.t()) :: :ok
  def retract_slots(tx_id, object, slots) do
    write_command(tx_id, {:retract_slots, {object, slots}})
  end

  @spec send_async(non_neg_integer(), AL.Var.t(), AL.Var.t(), AL.Var.t()) :: :ok
  def send_async(tx_id, object, method, args) do
    write_command(tx_id, {:send_async, {object, method, args}})
  end

  @spec send_elixir(non_neg_integer(), pid(), term()) :: :ok
  def send_elixir(tx_id, pid, message) do
    write_command(tx_id, {:send_elixir, {pid, message}})
  end

  @spec write_command(non_neg_integer(), command()) :: :ok
  def write_command(tx_id, command) do
    {t1, _t2} = inc_system_time()
    :mnesia.write({:command, t1, tx_id, command})
  end

  @doc """
  I increase the monotonic system time of the log
  """
  def inc_system_time() do
    t = system_time()
    :mnesia.dirty_write({:meta, :system_time, t + 1})
    {t, t + 1}
  end

  @spec fresh_id() :: atom()
  def fresh_id() do
    label =
      case :mnesia.dirty_read(:meta, :id_counter) do
        [{:meta, :id_counter, n}] -> n
        [] -> 0
      end

    :mnesia.dirty_write({:meta, :id_counter, label + 1})
    :"##{label}"
  end

  @spec id_label(atom()) :: non_neg_integer()
  def id_label(id) do
    meta_label(:id_label, :id_counter, id)
  end

  @spec fresh_scope() :: String.t()
  def fresh_scope() do
    n =
      case :mnesia.dirty_read(:meta, :scope_counter) do
        [{:meta, :scope_counter, n}] -> n
        [] -> 0
      end

    :mnesia.dirty_write({:meta, :scope_counter, n + 1})
    Integer.to_string(n)
  end

  @spec scope_label(String.t()) :: non_neg_integer()
  def scope_label(scope) do
    meta_label(:scope_label, :scope_counter, scope)
  end

  defp meta_label(namespace, counter_key, key) do
    meta_key = {namespace, key}

    case :mnesia.dirty_read(:meta, meta_key) do
      [{:meta, ^meta_key, label}] ->
        label

      [] ->
        label =
          case :mnesia.dirty_read(:meta, counter_key) do
            [{:meta, ^counter_key, n}] -> n
            [] -> 0
          end

        :mnesia.dirty_write({:meta, counter_key, label + 1})
        :mnesia.dirty_write({:meta, meta_key, label})
        label
    end
  end
end
