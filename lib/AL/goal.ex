defmodule AL.Goal.StorableError do
  @moduledoc "A typed error for an ephemeral source term in durable data."

  defexception [:term, :reason]

  @type t() :: %__MODULE__{term: term(), reason: term()}

  @impl true
  def message(%__MODULE__{term: term, reason: reason}) do
    "cannot store ephemeral source term #{inspect(term)}: #{inspect(reason)}"
  end
end

defmodule AL.Goal do
  use TypedStruct

  @type command() ::
          AL.Goal.SetClass.t()
          | AL.Goal.SetSuper.t()
          | AL.Goal.SetMethod.t()
          | AL.Goal.SetOapply.t()
          | AL.Goal.SetSlot.t()
          | AL.Goal.RetractClass.t()
          | AL.Goal.RetractSuper.t()
          | AL.Goal.RetractMethod.t()
          | AL.Goal.RetractOapply.t()
          | AL.Goal.RetractSlot.t()
          | AL.Goal.SendAsync.t()
          | AL.Goal.SendElixir.t()
          | AL.Goal.EmitEffect.t()

  @type instructions() ::
          AL.Goal.GetClass.t()
          | AL.Goal.GetSuper.t()
          | AL.Goal.GetMethod.t()
          | AL.Goal.GetCommand.t()
          | AL.Goal.BranchEdge.t()
          | AL.Goal.BranchMeta.t()
          | AL.Goal.CurrentBranch.t()
          | AL.Goal.GetOapply.t()
          | AL.Goal.MethodSource.t()
          | AL.Goal.TransactionSource.t()
          | AL.Goal.AssertValidClauseSelf.t()
          | AL.Goal.OApply.t()
          | AL.Goal.Cut.t()
          | AL.Goal.Implies.t()
          | AL.Goal.Or.t()
          | AL.Goal.Forall.t()
          | AL.Goal.Findall.t()
          | AL.Goal.GetSlots.t()
          | AL.Goal.GetSlotAt.t()
          | AL.Goal.Gensym.t()
          | AL.Goal.Format.t()
          | AL.Goal.Not.t()
          | AL.Goal.Eq.t()
          | AL.Goal.Equal.t()
          | AL.Goal.Variant.t()
          | AL.Goal.CopyTerm.t()
          | AL.Goal.Compound.t()
          | AL.Goal.StringCodes.t()
          | AL.Goal.AtomString.t()
          | AL.Goal.Atom.t()
          | AL.Goal.Functor.t()
          | AL.Goal.Dif.t()
          | AL.Goal.Isa.t()
          | AL.Goal.Compare.t()
          | AL.Goal.FloorDivide.t()
          | AL.Goal.Either.t()
          | AL.Goal.AllDif.t()
          | AL.Goal.InDomain.t()
          | AL.Goal.Ground.t()
          | AL.Goal.Label.t()
          | AL.Goal.IsVar.t()
          | AL.Goal.Freeze.t()
          | AL.Goal.Call.t()
          | AL.Goal.Send.t()
          | AL.Goal.CallNextMethod.t()
          | AL.Goal.SourceScope.t()
          | AL.Goal.Fail.t()
          | AL.Goal.Pass.t()
          | AL.Goal.Comment.t()

  @type t() :: command() | instructions()

  # Commands ----------------------------------------
  typedstruct enforce: true, module: SetClass do
    field(:object, AL.Var.t())
    field(:class, AL.Var.t())
  end

  typedstruct enforce: true, module: SetSuper do
    field(:object, AL.Var.t())
    field(:super, AL.Var.t())
  end

  typedstruct enforce: true, module: SetMethod do
    field(:object, AL.Var.t())
    field(:name, AL.Var.t())
    field(:id, AL.Var.t())
  end

  typedstruct enforce: true, module: SetOapply do
    field(:object, AL.Var.t())
    field(:seq, :next | non_neg_integer())
    field(:head, AL.Var.t())
    field(:body, [AL.Goal.t()])
  end

  # one write goal for any ivar, aos or soa -- routing resolved in the
  # interp handler, not carried here.
  typedstruct enforce: true, module: SetSlot do
    field(:object, AL.Var.t())
    field(:key, AL.Var.t())
    field(:value, AL.Var.t())
  end

  typedstruct enforce: true, module: RetractClass do
    field(:object, AL.Var.t())
    field(:class, AL.Var.t())
  end

  typedstruct enforce: true, module: RetractSuper do
    field(:object, AL.Var.t())
    field(:super, AL.Var.t())
  end

  typedstruct enforce: true, module: RetractMethod do
    field(:object, AL.Var.t())
    field(:name, AL.Var.t())
    field(:id, AL.Var.t())
  end

  typedstruct enforce: true, module: RetractOapply do
    field(:object, AL.Var.t())
    field(:head, AL.Var.t())
  end

  typedstruct enforce: true, module: RetractSlot do
    field(:object, AL.Var.t())
    field(:key, AL.Var.t())
  end

  typedstruct enforce: true, module: SendAsync do
    field(:object, AL.Var.t())
    field(:method, AL.Var.t())
    field(:args, AL.Var.t())
  end

  typedstruct enforce: true, module: SendElixir do
    field(:pid, pid())
    field(:message, term())
  end

  typedstruct enforce: true, module: EmitEffect do
    field(:effect, AL.Var.t())
    field(:provider, AL.Var.t())
    field(:operation, AL.Var.t())
    field(:arguments, AL.Var.t())
  end

  # General Goals -----------------------------------

  typedstruct enforce: true, module: GetClass do
    field(:object, AL.Var.t())
    field(:class, AL.Var.t())
  end

  typedstruct enforce: true, module: GetSuper do
    field(:object, AL.Var.t())
    field(:super, AL.Var.t())
  end

  typedstruct enforce: true, module: GetMethod do
    field(:object, AL.Var.t())
    field(:name, AL.Var.t())
    field(:id, AL.Var.t())
  end

  typedstruct enforce: true, module: BranchEdge do
    field(:parent, AL.Var.t())
    field(:child, AL.Var.t())
  end

  typedstruct enforce: true, module: BranchMeta do
    field(:branch, AL.Var.t())
    field(:key, AL.Var.t())
    field(:value, AL.Var.t())
  end

  typedstruct enforce: true, module: CurrentBranch do
    field(:branch, AL.Var.t())
  end

  typedstruct enforce: true, module: GetCommand do
    field(:transaction, AL.Var.t())
    field(:time, AL.Var.t())
    field(:operation, AL.Var.t())
  end

  typedstruct enforce: true, module: GetOapply do
    field(:object, AL.Var.t())
    field(:seq, AL.Var.t())
    field(:head, AL.Var.t())
    field(:body, [AL.Goal.t()])
  end

  typedstruct enforce: true, module: TransactionSource do
    field(:tx, AL.Var.t())
    field(:text, AL.Var.t())
    field(:origin, AL.Var.t())
  end

  typedstruct enforce: true, module: MethodSource do
    field(:object, AL.Var.t())
    field(:seq, AL.Var.t())
    field(:text, AL.Var.t())
    field(:provenance, AL.Var.t())
  end

  # Narrowly-scoped validation, not a general primitive -- called only from
  # :defmethod's own accretion body (bootstrap.ex). Rejects a super: :value
  # class's clause binding self to a bare atom (durable identity's own
  # shape), which a durable classification of that same atom would be
  # reachable through two independent ways at once. No-op for anything else.
  typedstruct enforce: true, module: AssertValidClauseSelf do
    field(:class, AL.Var.t())
    field(:head, AL.Var.t())
  end

  typedstruct enforce: true, module: OApply do
    field(:method_id, AL.Var.t())
    field(:args, AL.Var.t())
  end

  typedstruct enforce: true, module: Cut do
  end

  typedstruct enforce: true, module: Implies do
    field(:condition, [AL.Goal.t()])
    field(:then, [AL.Goal.t()])
    field(:otherwise, [AL.Goal.t()])
  end

  typedstruct enforce: true, module: Or do
    field(:or, [AL.Goal.t()])
    field(:then, [AL.Goal.t()])
  end

  typedstruct enforce: true, module: Forall do
    field(:condition, [AL.Goal.t()])
    field(:body, [AL.Goal.t()])
  end

  typedstruct enforce: true, module: Findall do
    field(:template, AL.Var.t())
    field(:condition, [AL.Goal.t()])
    field(:result, AL.Var.t())
  end

  typedstruct enforce: true, module: GetSlots do
    field(:object, AL.Var.t())
    field(:key, AL.Var.t())
    field(:value, AL.Var.t())
    field(:store, :auto | :aos | :soa, default: :auto)
  end

  # `object`/`key` ground (a keyed history read, no scan). `value` and `t`
  # are ordinary bindable positions like any other relation's -- ground `t`
  # filters to the row whose `[tx_from, tx_to)` interval contains it (via
  # `AL.Var.in_bounds?/2`); open `t` fans out one choicepoint per row and
  # posts that row's interval as `t`'s real `ConstraintSet.bounds`
  # (`AL.Var.add_bounds/3`) rather than returning inert data -- a still-open
  # `t` stays a live, further-narrowable CLP var, not a dead end. See
  # `AL.JAM.Relation`'s handler and `AL.Object`'s `@relations` doc (no
  # separate history table -- this reads straight off `slots`'s bag, both
  # open and closed rows).
  typedstruct enforce: true, module: GetSlotAt do
    field(:object, AL.Var.t())
    field(:key, AL.Var.t())
    field(:value, AL.Var.t())
    field(:t, AL.Var.t())
  end

  typedstruct enforce: true, module: Gensym do
    field(:var, AL.Var.t())
  end

  typedstruct enforce: true, module: Format do
    field(:control, AL.Var.t())
    field(:args, AL.Var.t())
  end

  typedstruct enforce: true, module: Not do
    field(:condition, [AL.Goal.t()])
  end

  typedstruct enforce: true, module: Eq do
    field(:a, AL.Var.t())
    field(:b, AL.Var.t())
  end

  typedstruct enforce: true, module: Equal do
    field(:a, AL.Var.t())
    field(:b, AL.Var.t())
  end

  typedstruct enforce: true, module: Variant do
    field(:a, AL.Var.t())
    field(:b, AL.Var.t())
  end

  typedstruct enforce: true, module: Compound do
    field(:name, AL.Var.t())
    field(:args, AL.Var.t())
  end

  typedstruct enforce: true, module: CopyTerm do
    field(:term, AL.Var.t())
    field(:copy, AL.Var.t())
    field(:goals, AL.Var.t())
  end

  typedstruct enforce: true, module: Functor do
    field(:term, AL.Var.t())
    field(:name, AL.Var.t())
    field(:args, AL.Var.t())
  end

  typedstruct enforce: true, module: StringCodes do
    field(:string, AL.Var.t())
    field(:codes, AL.Var.t())
  end

  typedstruct enforce: true, module: AtomString do
    field(:atom, AL.Var.t())
    field(:string, AL.Var.t())
  end

  typedstruct enforce: true, module: Atom do
    field(:term, AL.Var.t())
  end

  typedstruct enforce: true, module: Dif do
    field(:a, AL.Var.t())
    field(:b, AL.Var.t())
  end

  typedstruct enforce: true, module: Isa do
    field(:object, AL.Var.t())
    field(:class, AL.Var.t())
  end

  typedstruct enforce: true, module: Compare do
    field(:op, atom())
    field(:a, AL.Var.t())
    field(:b, AL.Var.t())
  end

  typedstruct enforce: true, module: FloorDivide do
    field(:dividend, AL.Var.t())
    field(:divisor, AL.Var.t())
    field(:quotient, AL.Var.t())
  end

  # `left or right` (CLP(FD) `#\/`) — the constraint that *at least one*
  # side holds, held and propagated directly (`AL.Var.Bounds.either/4`): no
  # boolean anywhere, surface or internal, just the two sides themselves.
  # Resolves by elimination once one side is provably infeasible; the other
  # then gets applied for real. `left`/`right` are themselves `Compare`
  # goals (already-lowered `=`/`< > <= >=` expressions).
  typedstruct enforce: true, module: Either do
    field(:left, Compare.t())
    field(:right, Compare.t())
  end

  # "var must end up being one of these" — a real constraint on the var
  # (narrows/intersects across repeated posts, checked at bind time), not a
  # class with a :domain method. Runtime-only, like Label, not in @forms.
  typedstruct enforce: true, module: InDomain do
    field(:var, AL.Var.t())
    field(:values, AL.Var.t())
  end

  typedstruct enforce: true, module: AllDif do
    field(:vars, AL.Var.t())
  end

  typedstruct enforce: true, module: Ground do
    field(:term, AL.Var.t())
  end

  # CLP(FD)-style labeling: a no-op if `term` is already ground, otherwise
  # enumerates its propagated `bounds` interval as ordinary backtracking
  # alternatives — the one place bounds consistency (`Compare`) actually
  # forces concreteness, since narrowing alone never does.
  typedstruct enforce: true, module: Label do
    field(:term, AL.Var.t())
  end

  typedstruct enforce: true, module: IsVar do
    field(:term, AL.Var.t())
  end

  typedstruct enforce: true, module: Freeze do
    field(:var, AL.Var.t())
    field(:goals, [AL.Goal.t()])
  end

  typedstruct enforce: true, module: Call do
    field(:head, [AL.Var.t()])
    field(:body, [AL.Goal.t()] | AL.Var.variable())
    field(:args, [AL.Var.t()])
  end

  typedstruct enforce: true, module: Send do
    field(:object, AL.Var.t())
    field(:method, AL.Var.t())
    field(:args, AL.Var.t())
  end

  typedstruct enforce: true, module: SourceScope do
    field(:capture_id, term())
    field(:goals, [AL.Goal.t()])
  end

  typedstruct enforce: true, module: CallNextMethod do
    field(:self, AL.Var.t())
    field(:args, AL.Var.t())
  end

  typedstruct enforce: true, module: Fail do
  end

  typedstruct enforce: true, module: Pass do
  end

  # Authored prose, stored so a definition stays fully regenerable. Inert at
  # run time, like Pass.
  typedstruct enforce: true, module: Comment do
    field(:text, String.t())
  end

  # struct <-> stored tuple. `:term` fields copy as-is, `:goals` fields recurse.
  @forms [
    {SetClass, :set_class, [object: :term, class: :term]},
    {SetSuper, :set_super, [object: :term, super: :term]},
    {SetMethod, :set_method, [object: :term, name: :term, id: :term]},
    {SetOapply, :set_oapply, [object: :term, seq: :term, head: :term, body: :goals]},
    {SetSlot, :set_slot, [object: :term, key: :term, value: :term]},
    {RetractClass, :retract_class, [object: :term, class: :term]},
    {RetractSuper, :retract_super, [object: :term, super: :term]},
    {RetractMethod, :retract_method, [object: :term, name: :term, id: :term]},
    {RetractOapply, :retract_oapply, [object: :term, head: :term]},
    {RetractSlot, :retract_slot, [object: :term, key: :term]},
    {SendAsync, :send_async, [object: :term, method: :term, args: :term]},
    {SendElixir, :send_elixir, [pid: :term, message: :term]},
    {EmitEffect, :emit_effect,
     [effect: :term, provider: :term, operation: :term, arguments: :term]},
    {GetClass, :get_class, [object: :term, class: :term]},
    {GetSuper, :get_super, [object: :term, super: :term]},
    {GetMethod, :get_method, [object: :term, name: :term, id: :term]},
    {GetCommand, :get_command, [transaction: :term, time: :term, operation: :term]},
    {GetOapply, :get_oapply, [object: :term, seq: :term, head: :term, body: :term]},
    {TransactionSource, :transaction_source, [tx: :term, text: :term, origin: :term]},
    {MethodSource, :method_source, [object: :term, seq: :term, text: :term, provenance: :term]},
    {AssertValidClauseSelf, :assert_valid_clause_self, [class: :term, head: :term]},
    {OApply, :oapply, [method_id: :term, args: :term]},
    {SourceScope, :source_scope, [capture_id: :term, goals: :goals]},
    {Implies, :implies, [condition: :goals, then: :goals, otherwise: :goals]},
    {Or, :or, [or: :goals, then: :goals]},
    {Forall, :forall, [condition: :goals, body: :goals]},
    {Findall, :findall, [template: :term, condition: :goals, result: :term]},
    {GetSlots, :get_slot, [object: :term, key: :term, value: :term, store: :term]},
    {GetSlotAt, :slot_at, [object: :term, key: :term, value: :term, t: :term]},
    {Gensym, :gensym, [var: :term]},
    {Format, :format, [control: :term, args: :term]},
    {Not, :not, [condition: :goals]},
    {Eq, :=, [a: :term, b: :term]},
    {Equal, :equal, [a: :term, b: :term]},
    {Variant, :variant, [a: :term, b: :term]},
    {CopyTerm, :copy_term, [term: :term, copy: :term, goals: :term]},
    {Compound, :compound, [name: :term, args: :term]},
    {StringCodes, :string_codes, [string: :term, codes: :term]},
    {AtomString, :atom_string, [atom: :term, string: :term]},
    {Atom, :atom, [term: :term]},
    {Functor, :functor, [term: :term, name: :term, args: :term]},
    {BranchEdge, :branch_edge, [parent: :term, child: :term]},
    {BranchMeta, :branch_meta, [branch: :term, key: :term, value: :term]},
    {CurrentBranch, :current_branch, [branch: :term]},
    {Compare, :compare, [op: :term, a: :term, b: :term]},
    {FloorDivide, :floor_divide, [dividend: :term, divisor: :term, quotient: :term]},
    {Either, :either, [left: :term, right: :term]},
    {AllDif, :all_dif, [vars: :term]},
    {Ground, :ground, [term: :term]},
    {IsVar, :var, [term: :term]},
    {Dif, :dif, [a: :term, b: :term]},
    {Isa, :isa, [object: :term, class: :term]},
    {InDomain, :in_domain, [var: :term, values: :term]},
    {Label, :label, [term: :term]},
    {Freeze, :freeze, [var: :term, goals: :goals]},
    {Call, :call, [head: :term, body: :goals, args: :term]},
    {Send, :send, [object: :term, method: :term, args: :term]},
    {CallNextMethod, :call_next_method, [self: :term, args: :term]},
    {Comment, :comment, [text: :term]}
  ]

  @calls [
    {:class, GetClass, [:object, :class], %{}},
    {:super, GetSuper, [:object, :super], %{}},
    {:method, GetMethod, [:object, :name, :id], %{}},
    {:clause, GetOapply, [:object, :head, :body], %{seq: {:"$var", "_"}}},
    {:clause, GetOapply, [:object, :seq, :head, :body], %{}},
    {:slot, GetSlots, [:object, :key, :value], %{store: :auto}},
    {:slot, GetSlots, [:object, :key, :value, :store], %{}},
    {:send, Send, [:object, :method], %{args: []}},
    {:send, Send, [:object, :method, :args], %{}},
    {:send_async, SendAsync, [:object, :method], %{args: []}},
    {:send_async, SendAsync, [:object, :method, :args], %{}},
    {:send_elixir, SendElixir, [:pid, :message], %{}},
    {:gensym, Gensym, [:var], %{}},
    {:ground, Ground, [:term], %{}},
    {:label, Label, [:term], %{}},
    {:var, IsVar, [:term], %{}},
    {:dif, Dif, [:a, :b], %{}},
    {:variant, Variant, [:a, :b], %{}},
    {:copy_term, CopyTerm, [:term, :copy, :goals], %{}},
    {:string_codes, StringCodes, [:string, :codes], %{}},
    {:atom_string, AtomString, [:atom, :string], %{}},
    {:atom, Atom, [:term], %{}},
    {:functor, Functor, [:term, :name, :args], %{}},
    {:isa, Isa, [:object, :class], %{}},
    {:in_domain, InDomain, [:var, :values], %{}},
    {:all_dif, AllDif, [:vars], %{}},
    {:floor_divide, FloorDivide, [:dividend, :divisor, :quotient], %{}},
    {:vm_assert_valid_clause_self, AssertValidClauseSelf, [:class, :head], %{}},
    {:vm_command, GetCommand, [:transaction, :time, :operation], %{}},
    {:vm_branch, BranchEdge, [:parent, :child], %{}},
    {:vm_branch_meta, BranchMeta, [:branch, :key, :value], %{}},
    {:vm_current_branch, CurrentBranch, [:branch], %{}},
    {:vm_transaction_source, TransactionSource, [:tx, :text, :origin], %{}},
    {:vm_method_source, MethodSource, [:object, :seq, :text, :provenance], %{}},
    {:vm_set_class, SetClass, [:object, :class], %{}},
    {:vm_set_super, SetSuper, [:object, :super], %{}},
    {:vm_set_method, SetMethod, [:object, :name, :id], %{}},
    {:vm_set_slot, SetSlot, [:object, :key, :value], %{}},
    {:vm_slot_at, GetSlotAt, [:object, :key, :value, :t], %{}},
    {:vm_retract_class, RetractClass, [:object, :class], %{}},
    {:vm_retract_super, RetractSuper, [:object, :super], %{}},
    {:vm_retract_method, RetractMethod, [:object, :name, :id], %{}},
    {:vm_retract_oapply, RetractOapply, [:object, :head], %{}},
    {:vm_retract_slot, RetractSlot, [:object, :key], %{}},
    {:vm_format, Format, [:control, :args], %{}},
    {:vm_emit_effect, EmitEffect, [:effect, :provider, :operation, :arguments], %{}}
  ]

  @call_forms Map.new(@calls, fn {name, module, fields, defaults} ->
                {{name, length(fields)}, {module, fields, defaults}}
              end)

  @doc "The names of the calls that read as a goal other than a send."
  @spec call_names() :: [atom()]
  def call_names, do: @calls |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  @doc "The goal an AL call reads as, when its name and arity name one."
  @spec from_call(atom(), [term()]) :: t() | nil
  def from_call(name, args) do
    case Map.fetch(@call_forms, {name, length(args)}) do
      {:ok, {module, fields, defaults}} ->
        struct(module, Map.merge(defaults, Map.new(Enum.zip(fields, args))))

      :error ->
        nil
    end
  end

  @doc "The shortest AL call that reads back as this goal."
  @spec to_call(t()) :: {atom(), [term()]} | nil
  def to_call(%module{} = goal) do
    Enum.find_value(@calls, fn {name, call_module, fields, defaults} ->
      if call_module == module and
           Enum.all?(defaults, fn {key, value} -> Map.fetch!(goal, key) == value end),
         do: {name, Enum.map(fields, &Map.fetch!(goal, &1))}
    end)
  end

  @arithmetic [:+, :-, :*, :/, :**, :rem]
  @comparisons [:<, :>, :<=, :>=]

  @doc "Whether `term` is a compound term: a goal value, rather than a map, list or atom."
  @spec compound?(term()) :: boolean()
  def compound?(%{__struct__: module}),
    do: String.starts_with?(Elixir.Atom.to_string(module), "Elixir.AL.Goal.")

  def compound?(_term), do: false

  @doc "The name and arguments a goal is written with, receiver first for a send."
  @spec call_form(term()) :: {atom(), [term()]} | nil
  def call_form(%Compound{name: name, args: args}), do: {name, args}

  def call_form(%Send{object: object, method: method, args: args}) when is_list(args),
    do: if(named?(method), do: {method, [object | args]})

  def call_form(%Compare{op: op, a: a, b: b}), do: {op, [a, b]}
  def call_form(%Either{left: left, right: right}), do: {:or, [left, right]}
  def call_form(%Eq{a: a, b: b}), do: {:=, [a, b]}
  def call_form(%Equal{a: a, b: b}), do: {:==, [a, b]}
  def call_form(%CallNextMethod{self: self, args: args}), do: {:call_next_method, [self | args]}
  def call_form(%Not{condition: condition}), do: {:not, [condition]}
  def call_form(%Forall{condition: condition, body: body}), do: {:forall, [condition, body]}
  def call_form(%Freeze{var: var, goals: goals}), do: {:freeze, [var, goals]}

  def call_form(%Findall{template: template, condition: condition, result: result}),
    do: {:findall, [template, result, condition]}

  def call_form(%OApply{method_id: method_id, args: args}) when is_list(args) do
    if named?(method_id) and
         (method_id in @arithmetic or args == [] or AL.Syntax.primitive?(method_id)),
       do: {method_id, args}
  end

  def call_form(%Cut{}), do: {:cut, []}
  def call_form(%Fail{}), do: {:fail, []}
  def call_form(%Pass{}), do: {:pass, []}
  def call_form(goal) when is_struct(goal), do: to_call(goal)
  def call_form(_term), do: nil

  @doc "The compound term with this name and these arguments."
  @spec from_call_form(atom(), [term()]) :: t()
  def from_call_form(name, args), do: %Compound{name: name, args: args}

  @statements [:defclass, :extend_class, :clear_method, :defprogram, :defpackage]

  @doc "The goal a compound runs as, once it is called."
  @spec lower(term()) :: t()
  def lower(%Compound{name: name, args: args}), do: lower(name, args)
  def lower(goal), do: goal

  @spec lower(atom(), [term()]) :: t()
  def lower(:cut, []), do: %Cut{}
  def lower(:fail, []), do: %Fail{}
  def lower(:pass, []), do: %Pass{}

  def lower(:";", [[%Compound{name: :->, args: [condition, then]}], otherwise]),
    do: %Implies{condition: goals(condition), then: goals(then), otherwise: goals(otherwise)}

  def lower(:";", [left, right]), do: %Or{or: goals(left), then: goals(right)}

  def lower(:->, [condition, then]),
    do: %Implies{condition: goals(condition), then: goals(then), otherwise: [%Fail{}]}

  def lower(op, [a, b]) when op in @comparisons, do: %Compare{op: op, a: a, b: b}
  def lower(:=, [a, b]), do: %Eq{a: a, b: b}
  def lower(:==, [a, b]), do: %Equal{a: a, b: b}

  def lower(:or, [left, right]),
    do: %Either{left: constraint(lower(left)), right: constraint(lower(right))}

  def lower(op, args) when op in @arithmetic, do: %OApply{method_id: op, args: args}
  def lower(:call_next_method, [self | args]), do: %CallNextMethod{self: self, args: args}
  def lower(:not, [condition]), do: %Not{condition: goals(condition)}

  def lower(:forall, [condition, body]),
    do: %Forall{condition: goals(condition), body: goals(body)}

  def lower(:freeze, [var, body]), do: %Freeze{var: var, goals: goals(body)}

  def lower(:findall, [template, result, condition]),
    do: %Findall{template: template, condition: goals(condition), result: result}

  def lower(:defmethod, [owner, selector, head, body]),
    do: %OApply{method_id: :defmethod, args: [owner, selector, head, goals(body)]}

  def lower(:lambda, [arguments, method, body]),
    do: %Send{object: arguments, method: :lambda, args: [method, goals(body)]}

  def lower(:spawn, [body]), do: %OApply{method_id: :spawn_transaction, args: [goals(body)]}

  def lower(:await, [effect, head, body]),
    do: %OApply{method_id: :await_effect, args: [effect, head, goals(body)]}

  def lower(:vm_source_scope, [capture_id, body]),
    do: %SourceScope{capture_id: capture_id, goals: goals(body)}

  def lower(:call, [head, body, args]), do: %Call{head: head, body: goals(body), args: args}

  def lower(:vm_set_oapply, [object, head, body]),
    do: %SetOapply{object: object, seq: :next, head: head, body: goals(body)}

  def lower(:vm_set_oapply, [object, seq, head, body]),
    do: %SetOapply{object: object, seq: seq, head: head, body: goals(body)}

  def lower(:comment, [text]) when is_binary(text), do: %Comment{text: text}
  def lower(:vm_oapply, [method_id, args]), do: %OApply{method_id: method_id, args: args}

  def lower(name, args) do
    cond do
      name in @statements -> %OApply{method_id: name, args: args}
      AL.Syntax.primitive?(name) -> %OApply{method_id: name, args: args}
      goal = from_call(name, args) -> goal
      args == [] -> %OApply{method_id: name, args: []}
      true -> %Send{object: hd(args), method: name, args: tl(args)}
    end
  end

  defp goals(goals) when is_list(goals), do: goals
  defp goals(goal), do: if(AL.Var.var?(goal), do: goal, else: [goal])

  defp named?(name), do: is_atom(name)

  defp constraint(%Eq{a: a, b: b}), do: %Compare{op: :=, a: a, b: b}
  defp constraint(goal), do: goal

  @to_form Map.new(@forms, fn {mod, tag, fields} -> {mod, {tag, fields}} end)
  @from_form Map.new(@forms, fn {mod, tag, fields} -> {tag, {mod, fields}} end)

  @type stored() :: tuple() | atom()

  @doc "Validate that no ephemeral source term can reach durable storage."
  @spec validate_storable(term()) :: :ok | {:error, AL.Goal.StorableError.t()}
  def validate_storable(term) do
    case invalid_storable(term) do
      nil -> :ok
      {invalid, reason} -> {:error, %AL.Goal.StorableError{term: invalid, reason: reason}}
    end
  end

  @spec validate_storable!(term()) :: :ok
  def validate_storable!(term) do
    case validate_storable(term) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @doc "Serialize one goal struct to its stored tuple form."
  @spec to_stored(term()) :: stored()
  def to_stored(term) do
    validate_storable!(term)
    do_to_stored(term)
  end

  defp do_to_stored(%Cut{}), do: :cut
  defp do_to_stored(%Fail{}), do: :fail
  defp do_to_stored(%Pass{}), do: :pass

  defp do_to_stored(goal) when is_struct(goal) do
    case Map.fetch(@to_form, goal.__struct__) do
      {:ok, {tag, fields}} ->
        List.to_tuple([
          tag | Enum.map(fields, fn {name, kind} -> store(kind, Map.fetch!(goal, name)) end)
        ])

      :error ->
        goal
    end
  end

  defp do_to_stored([head | tail]), do: [do_to_stored(head) | do_to_stored(tail)]

  defp do_to_stored(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&do_to_stored/1) |> List.to_tuple()

  defp do_to_stored(term) when is_map(term),
    do: Map.new(term, fn {key, value} -> {do_to_stored(key), do_to_stored(value)} end)

  defp do_to_stored(other), do: other

  defp store(:term, value), do: do_to_stored(value)
  defp store(:goals, goals) when is_list(goals), do: Enum.map(goals, &do_to_stored/1)
  defp store(:goals, other), do: do_to_stored(other)

  defp invalid_storable(%SourceScope{capture_id: capture_id, goals: goals} = scope) do
    if AL.Var.var?(capture_id), do: invalid_storable(goals), else: {scope, :concrete_source_scope}
  end

  defp invalid_storable(%AL.Source.Ref{} = ref), do: {ref, :source_ref}

  defp invalid_storable({evaluation_ref, ordinal} = capture_id)
       when is_reference(evaluation_ref) and is_integer(ordinal),
       do: {capture_id, :capture_id}

  defp invalid_storable([]), do: nil

  defp invalid_storable([head | tail]),
    do: invalid_storable(head) || invalid_storable(tail)

  defp invalid_storable(term) when is_struct(term),
    do: term |> Map.from_struct() |> invalid_storable()

  defp invalid_storable(term) when is_map(term) do
    Enum.find_value(term, fn {key, value} -> invalid_storable(key) || invalid_storable(value) end)
  end

  defp invalid_storable(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.find_value(&invalid_storable/1)

  defp invalid_storable(_term), do: nil

  @doc "Rebuild a goal struct from its stored tuple form (inverse of to_stored/1)."
  @spec from_stored(stored()) :: t()
  def from_stored(:cut), do: %Cut{}
  def from_stored(:fail), do: %Fail{}
  def from_stored(:pass), do: %Pass{}

  def from_stored(stored) when is_tuple(stored) do
    [tag | args] = Tuple.to_list(stored)

    case Map.fetch(@from_form, tag) do
      {:ok, {mod, fields}} ->
        struct(mod, Enum.zip_with(fields, args, fn {name, kind}, v -> {name, load(kind, v)} end))

      :error ->
        stored
    end
  end

  def from_stored(other), do: other

  # Mirrors store(:term, v)'s recursive to_stored on the write side — a
  # :term value can itself nest a stored goal tuple (arithmetic inside an
  # is/oapply arg list), so this has to recurse the same way, not just
  # convert the top tag.
  defp load(:term, v), do: term_from_stored(v)
  defp load(:goals, gs) when is_list(gs), do: Enum.map(gs, &from_stored/1)
  defp load(:goals, other), do: other

  defp term_from_stored(t) when is_tuple(t) do
    case Map.fetch(@from_form, elem(t, 0)) do
      {:ok, _} -> from_stored(t)
      :error -> t |> Tuple.to_list() |> Enum.map(&term_from_stored/1) |> List.to_tuple()
    end
  end

  defp term_from_stored([h | t]), do: [term_from_stored(h) | term_from_stored(t)]
  defp term_from_stored(other), do: other
end
