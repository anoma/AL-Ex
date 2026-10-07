defmodule AL.JAM.IR.Lower do
  alias AL.{Goal, JAM.IR}

  for {module, kind, name, fields} <- [
        {Goal.InDomain, :constraint, :in_domain, [:var, :values]},
        {Goal.AllDif, :constraint, :all_dif, [:vars]},
        {Goal.FloorDivide, :constraint, :floor_divide, [:dividend, :divisor, :quotient]},
        {Goal.Variant, :primitive, :variant, [:a, :b]},
        {Goal.CopyTerm, :direct, :copy_term, [:term, :copy, :goals]},
        {Goal.Format, :direct, :format, [:control, :args]},
        {Goal.Label, :search, :label, [:term]},
        {Goal.Ground, :direct, :ground, [:term]},
        {Goal.IsVar, :direct, :is_var, [:term]},
        {Goal.GetSlots, :direct, :slot_get, [:object, :key, :value, :store]},
        {Goal.Equal, :primitive, :equal, [:a, :b]},
        {Goal.StringCodes, :primitive, :string_codes, [:string, :codes]},
        {Goal.AtomString, :primitive, :atom_string, [:atom, :string]},
        {Goal.Isa, :relation, :isa, [:object, :class]},
        {Goal.AssertValidClauseSelf, :mutation, :assert_valid_clause_self, [:class, :head]},
        {Goal.Gensym, :relation, :gensym, [:var]},
        {Goal.EmitEffect, :mutation, :emit_effect, [:effect, :provider, :operation, :arguments]},
        {Goal.SendAsync, :mutation, :send_async, [:object, :method, :args]},
        {Goal.SendElixir, :mutation, :send_elixir, [:pid, :message]},
        {Goal.SetClass, :mutation, :set_class, [:object, :class]},
        {Goal.SetSuper, :mutation, :set_super, [:object, :super]},
        {Goal.SetMethod, :mutation, :set_method, [:object, :name, :id]},
        {Goal.SetOapply, :mutation, :set_oapply, [:object, :seq, :head, :body]},
        {Goal.SetSlot, :mutation, :set_slot, [:object, :key, :value]},
        {Goal.RetractClass, :mutation, :retract_class, [:object, :class]},
        {Goal.RetractSuper, :mutation, :retract_super, [:object, :super]},
        {Goal.RetractMethod, :mutation, :retract_method, [:object, :name, :id]},
        {Goal.RetractOapply, :mutation, :retract_oapply, [:object, :head]},
        {Goal.RetractSlot, :mutation, :retract_slot, [:object, :key]},
        {Goal.TransactionSource, :relation, :transaction_source, [:tx, :text, :origin]},
        {Goal.MethodSource, :relation, :method_source, [:object, :seq, :text, :provenance]},
        {Goal.GetSlotAt, :relation, :slot_at, [:object, :key, :value, :t]},
        {Goal.GetCommand, :relation, :command, [:transaction, :time, :operation]},
        {Goal.BranchEdge, :relation, :branch_edge, [:parent, :child]},
        {Goal.BranchMeta, :relation, :branch_meta, [:branch, :key, :value]},
        {Goal.CurrentBranch, :relation, :current_branch, [:branch]},
        {Goal.GetSuper, :relation, :super, [:object, :super]},
        {Goal.GetMethod, :relation, :method, [:object, :name, :id]},
        {Goal.GetOapply, :relation, :clause, [:object, :seq, :head, :body]},
        {Goal.CallNextMethod, :control, :next, [:self, :args]},
        {Goal.Call, :callable, :call, [:head, :body, :args]}
      ] do
    def operation(%unquote(module){} = goal),
      do:
        IR.operation(
          unquote(kind),
          unquote(name),
          Enum.map(unquote(fields), &Map.fetch!(goal, &1))
        )
  end

  def operation(%Goal.Cut{}), do: IR.operation(:control, :cut, [])
  def operation(%Goal.Comment{}), do: IR.operation(:direct, :pass, [])

  def operation(%Goal.OApply{method_id: method, args: args}),
    do: IR.invoke(method, args) |> IR.Kernel.specialize()

  def operation(%Goal.Either{
        left: %Goal.Compare{op: lop, a: la, b: lb},
        right: %Goal.Compare{op: rop, a: ra, b: rb}
      }),
      do: IR.operation(:constraint, :either, [lop, la, lb, rop, ra, rb])

  def operation(%Goal.Implies{condition: condition, then: yes, otherwise: no}),
    do: IR.operation(:condition, nil, [condition, yes, no])

  def operation(%Goal.Findall{template: template, result: result, condition: condition}),
    do: scope(:collect, [template, result], %{condition: condition})

  def operation(%Goal.Forall{condition: condition, body: body}),
    do: scope(:forall, [], %{condition: condition, body: body})

  def operation(%Goal.Not{condition: condition}), do: scope(:negate, [], %{condition: condition})

  def operation(%Goal.Freeze{var: variable, goals: goals}),
    do: scope(:freeze, [variable], %{body: goals})

  def operation(%Goal.SourceScope{capture_id: id, goals: goals}),
    do: %{scope(:source_scope, [id], %{body: goals}) | retained_goals: goals}

  def operation(goal), do: IR.operation(:unsupported, nil, [goal])

  defp scope(name, args, regions), do: %{IR.operation(:scope, name, args) | regions: regions}
end
