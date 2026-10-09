defmodule AL.JAM.IR.Kernel do
  alias AL.JAM.IR

  def specialize(%IR{kind: :invoke, name: :map_get, args: [map, key, value]}),
    do: IR.operation(:direct, :map_get, [map, key, value])

  def specialize(%IR{kind: :invoke, name: :vm_map_put, args: [map, key, value, result]}),
    do: IR.operation(:direct, :map_put, [map, key, value, result])

  def specialize(%IR{kind: :invoke, name: :map_pairs, args: [map, pairs]}),
    do: IR.operation(:primitive, :map_pairs, [map, pairs])

  def specialize(%IR{kind: :invoke, name: :block_goals, args: [block, goals]}),
    do: IR.operation(:primitive, :block_goals, [block, goals])

  def specialize(%IR{kind: :invoke, name: :vm_fresh_id, args: [result]}),
    do: IR.operation(:relation, :fresh_id, [result])

  def specialize(%IR{kind: :invoke, name: :vm_cached_ivar_specs, args: args}),
    do: IR.operation(:relation, :ivar_specs, args)

  def specialize(%IR{kind: :invoke, name: :vm_cached_find_ivar_spec, args: args}),
    do: IR.operation(:relation, :ivar_spec, args)

  def specialize(%IR{kind: :invoke, name: :vm_current_tx, args: [result]}),
    do: IR.operation(:context, :tx_id, [result])

  def specialize(%IR{kind: :invoke, name: :vm_transaction_object, args: [result]}),
    do: IR.operation(:context, :transaction_object, [result])

  def specialize(%IR{kind: :invoke, name: :spawn_transaction, args: [goals]}),
    do: IR.operation(:relation, :schedule_transaction, [:ready, :none, [], goals])

  def specialize(%IR{kind: :invoke, name: :await_effect, args: [effect, head, goals]}),
    do: IR.operation(:relation, :schedule_transaction, [:waiting, effect, head, goals])

  def specialize(%IR{kind: :invoke, name: method, args: args} = operation) do
    if (AL.Syntax.primitive?(method) or method in [:spawn_transaction, :await_effect]) and
         proper_list?(args),
       do: IR.operation(:fail, nil, []),
       else: operation
  end

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_term), do: false
end
