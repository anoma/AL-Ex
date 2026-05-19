defmodule AL.Objects do
  @moduledoc """
  I am the in-memory store for AL objects
  """

  @type class_record() :: {:class, AL.Var.t(), AL.Var.t()}
  @type super_record() :: {:super, AL.Var.t(), AL.Var.t()}
  @type slots_record() :: {:slots, AL.Var.t(), AL.Var.t()}
  @type method_record() :: {:method, AL.Var.t(), AL.Var.t(), AL.Var.t()}
  @type oapply_record() :: {:oapply, AL.Var.t(), AL.Var.t(), [AL.goal()]}

  def setup() do
    case :mnesia.create_table(:class,
           attributes: [:object, :class],
           type: :bag,
           ram_copies: [node()]
         ) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
    end

    case :mnesia.create_table(:super,
           attributes: [:object, :super],
           type: :bag,
           ram_copies: [node()]
         ) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
    end

    case :mnesia.create_table(:slots,
           attributes: [:object, :slots],
           type: :bag,
           ram_copies: [node()]
         ) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
    end

    case :mnesia.create_table(:method,
           attributes: [:object, :method_name, :method_id],
           type: :bag,
           ram_copies: [node()]
         ) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
    end

    case :mnesia.create_table(:oapply,
           attributes: [:object, :head, :body],
           type: :bag,
           ram_copies: [node()]
         ) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
    end

    :mnesia.wait_for_tables([:class, :super, :slots, :method, :oapply], 5_000)

    hydrate_since(0)
  end

  @spec scan_class(AL.Var.t(), AL.Var.t()) :: [class_record()]
  def scan_class(self_pattern, class_pattern) do
    :mnesia.select(:class, [
      {AL.Var.to_mnesia_pattern({:class, self_pattern, class_pattern}), [], [:"$_"]}
    ])
  end

  @spec scan_super(AL.Var.t(), AL.Var.t()) :: [super_record()]
  def scan_super(self_pattern, super_pattern) do
    :mnesia.select(:super, [
      {AL.Var.to_mnesia_pattern({:super, self_pattern, super_pattern}), [], [:"$_"]}
    ])
  end

  @spec scan_slots(AL.Var.t(), AL.Var.t()) :: [slots_record()]
  def scan_slots(self_pattern, slots_pattern) do
    :mnesia.select(:slots, [
      {AL.Var.to_mnesia_pattern({:slots, self_pattern, slots_pattern}), [], [:"$_"]}
    ])
  end

  @spec scan_method(AL.Var.t(), AL.Var.t(), AL.Var.t()) :: [method_record()]
  def scan_method(self_pattern, method_name_pattern, method_id_pattern) do
    :mnesia.select(:method, [
      {AL.Var.to_mnesia_pattern({:method, self_pattern, method_name_pattern, method_id_pattern}),
       [], [:"$_"]}
    ])
  end

  @spec scan_oapply(AL.Var.t(), AL.Var.t(), AL.Var.t()) :: [oapply_record()]
  def scan_oapply(self_pattern, head_pattern, body_pattern) do
    :mnesia.select(:oapply, [
      {AL.Var.to_mnesia_pattern({:oapply, self_pattern, head_pattern, body_pattern}), [], [:"$_"]}
    ])
  end

  @spec set_class(AL.Var.t(), AL.Var.t()) :: :ok
  def set_class(object_pattern, class_pattern) do
    :mnesia.write({:class, object_pattern, class_pattern})
  end

  @spec set_super(AL.Var.t(), AL.Var.t()) :: :ok
  def set_super(object_pattern, super_pattern) do
    :mnesia.write({:super, object_pattern, super_pattern})
  end

  @spec set_method(AL.Var.t(), AL.Var.t(), AL.Var.t()) :: :ok
  def set_method(object_pattern, method_name_pattern, method_id_pattern) do
    :mnesia.write({:method, object_pattern, method_name_pattern, method_id_pattern})
  end

  @spec set_oapply(AL.Var.t(), AL.Var.t(), [AL.goal()]) :: :ok
  def set_oapply(object_pattern, head_pattern, body_pattern) do
    :mnesia.write({:oapply, object_pattern, head_pattern, body_pattern})
  end

  @spec set_slots(AL.Var.t(), AL.Var.t()) :: :ok
  def set_slots(object_pattern, slots_pattern) do
    :mnesia.write({:slots, object_pattern, slots_pattern})
  end

  def hydrate_event(op, event) do
    case op do
      :set_class ->
        {object, class} = event
        :mnesia.write({:class, object, class})

      :set_super ->
        {object, super} = event
        :mnesia.write({:super, object, super})

      :set_method ->
        {object, method_name, method_id} = event
        :mnesia.write({:method, object, method_name, method_id})

      :set_oapply ->
        {object, head, body} = event
        :mnesia.write({:oapply, object, head, body})

      :set_slots ->
        {object, slots} = event
        :mnesia.write({:slots, object, slots})
    end
  end

  def hydrate_since(t) do
    f = fn ->
      for {:command, _, _, {op, event}} <- AL.Command.commands_since(t) do
        hydrate_event(op, event)
      end
    end

    :mnesia.transaction(f)
  end
end
