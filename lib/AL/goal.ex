defmodule AL.Goal do
  use TypedStruct

  @type command() ::
          SetClass.t()
          | SetSuper.t()
          | SetMethod.t()
          | SetOapply.t()
          | SetSlots.t()
          | RetractClass.t()
          | RetractSuper.t()
          | RetractMethod.t()
          | RetractOapply.t()
          | RetractSlots.t()
          | SendAsync.t()
          | SendElixir.t()

  @type instructions() ::
          GetClass.t()
          | GetSuper.t()
          | GetMethod.t()
          | GetOapply.t()
          | AssertValidClauseSelf.t()
          | OApply.t()
          | Cut.t()
          | Implies.t()
          | Or.t()
          | Then.t()
          | Forall.t()
          | Findall.t()
          | GetSlots.t()
          | Gensym.t()
          | Print.t()
          | Not.t()
          | Unify.t()
          | Equal.t()
          | Dif.t()
          | Compare.t()
          | Either.t()
          | InDomain.t()
          | Ground.t()
          | Label.t()
          | IsVar.t()
          | Freeze.t()
          | Functor.t()
          | CallTerm.t()
          | Call.t()
          | Send.t()
          | SendQuery.t()
          | SendAsValue.t()
          | DurableCandidates.t()
          | CallNextMethod.t()
          | Fail.t()

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
    field(:seq, non_neg_integer())
    field(:head, AL.Var.t())
    field(:body, [AL.Goal.t()])
  end

  typedstruct enforce: true, module: SetSlots do
    field(:object, AL.Var.t())
    field(:slots, AL.Var.t())
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

  typedstruct enforce: true, module: RetractSlots do
    field(:object, AL.Var.t())
    field(:slots, AL.Var.t())
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

  typedstruct enforce: true, module: GetOapply do
    field(:object, AL.Var.t())
    field(:seq, non_neg_integer())
    field(:head, AL.Var.t())
    field(:body, [AL.Goal.t()])
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

  typedstruct enforce: true, module: Then do
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
  end

  typedstruct enforce: true, module: Gensym do
    field(:var, AL.Var.t())
  end

  typedstruct enforce: true, module: Print do
    field(:pattern, AL.Var.t())
  end

  typedstruct enforce: true, module: Not do
    field(:condition, [AL.Goal.t()])
  end

  typedstruct enforce: true, module: Unify do
    field(:a, AL.Var.t())
    field(:b, AL.Var.t())
  end

  typedstruct enforce: true, module: Equal do
    field(:a, AL.Var.t())
    field(:b, AL.Var.t())
  end

  typedstruct enforce: true, module: Dif do
    field(:a, AL.Var.t())
    field(:b, AL.Var.t())
  end

  typedstruct enforce: true, module: Compare do
    field(:op, atom())
    field(:a, AL.Var.t())
    field(:b, AL.Var.t())
  end

  # `left or right` (CLP(FD) `#\/`) — the constraint that *at least one*
  # side holds, held and propagated directly (`AL.Var.Bounds.either/4`): no
  # boolean anywhere, surface or internal, just the two sides themselves.
  # Resolves by elimination once one side is provably infeasible; the other
  # then gets applied for real. `left`/`right` are themselves `Compare`
  # goals (already-lowered `eq`/`< > <= >=` expressions).
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

  # Prolog's `functor/3` crossed with `=..`: `term` ground decomposes into
  # `name` (a tuple's first element, or the term itself if atomic) and `args`
  # (the tuple's remaining elements, or `[]` if atomic); `name`/`args` ground
  # with `term` unbound constructs the reverse.
  typedstruct enforce: true, module: Functor do
    field(:term, AL.Var.t())
    field(:name, AL.Var.t())
    field(:args, AL.Var.t())
  end

  # Prolog's `call/1`: re-dispatch a ground compound term as a `send`, treating
  # its first arg as the receiver and its functor as the selector.
  typedstruct enforce: true, module: CallTerm do
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
    field(:body, [AL.Goal.t()])
    field(:args, [AL.Var.t()])
  end

  typedstruct enforce: true, module: Send do
    field(:object, AL.Var.t())
    field(:method, AL.Var.t())
    field(:args, AL.Var.t())
  end

  typedstruct enforce: true, module: SendQuery do
    field(:object, AL.Var.t())
    field(:method, AL.Var.t())
    field(:args, AL.Var.t())
  end

  # Internal, dispatch-only: try `class`'s own clauses against a possibly-unbound
  # `object`, no construction/retrieval — see the "value" dispatch leg in dispatch/5.
  typedstruct enforce: true, module: SendAsValue do
    field(:class, AL.Var.t())
    field(:object, AL.Var.t())
    field(:method, AL.Var.t())
    field(:args, AL.Var.t())
  end

  # Internal, dispatch-only: the durable leg's placeholder — one choicepoint
  # standing in for the real per-object scan, which only happens if backtracking
  # (or a `Fail` immediately after push) actually reaches it. See "Deferred
  # durable candidates" in dispatch.ex.
  typedstruct enforce: true, module: DurableCandidates do
    field(:object, AL.Var.t())
    field(:method, AL.Var.t())
    field(:args, AL.Var.t())
  end

  typedstruct enforce: true, module: CallNextMethod do
    field(:self, AL.Var.t())
    field(:args, AL.Var.t())
  end

  typedstruct enforce: true, module: Fail do
  end

  @doc "Transform every leaf of a goal term with `fun`."
  @spec map(term(), (term() -> term())) :: term()
  def map({:"$fresh", _base, _scope} = leaf, fun), do: fun.(leaf)
  def map([], _fun), do: []
  def map([head | tail], fun), do: [map(head, fun) | map(tail, fun)]

  def map(term, fun) when is_struct(term),
    do: struct(term.__struct__, Map.new(Map.from_struct(term), fn {k, v} -> {k, map(v, fun)} end))

  def map(term, fun) when is_map(term),
    do: Map.new(term, fn {k, v} -> {map(k, fun), map(v, fun)} end)

  def map(term, fun) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&map(&1, fun)) |> List.to_tuple()

  def map(leaf, fun), do: fun.(leaf)

  @doc "Fold `fun` over every leaf of a goal term, in the same order as map/2."
  @spec reduce(term(), acc, (term(), acc -> acc)) :: acc when acc: var
  def reduce({:"$fresh", _base, _scope} = leaf, acc, fun), do: fun.(leaf, acc)
  def reduce([], acc, _fun), do: acc
  def reduce([head | tail], acc, fun), do: reduce(tail, reduce(head, acc, fun), fun)

  def reduce(term, acc, fun) when is_struct(term),
    do: Enum.reduce(Map.from_struct(term), acc, fn {_k, v}, a -> reduce(v, a, fun) end)

  def reduce(term, acc, fun) when is_map(term),
    do: Enum.reduce(term, acc, fn {k, v}, a -> reduce(v, reduce(k, a, fun), fun) end)

  def reduce(term, acc, fun) when is_tuple(term),
    do: term |> Tuple.to_list() |> reduce(acc, fun)

  def reduce(leaf, acc, fun), do: fun.(leaf, acc)

  # struct <-> stored tuple. `:term` fields copy as-is, `:goals` fields recurse.
  @forms [
    {SetClass, :set_class, [object: :term, class: :term]},
    {SetSuper, :set_super, [object: :term, super: :term]},
    {SetMethod, :set_method, [object: :term, name: :term, id: :term]},
    {SetOapply, :set_oapply, [object: :term, seq: :term, head: :term, body: :goals]},
    {SetSlots, :set_slots, [object: :term, slots: :term]},
    {RetractClass, :retract_class, [object: :term, class: :term]},
    {RetractSuper, :retract_super, [object: :term, super: :term]},
    {RetractMethod, :retract_method, [object: :term, name: :term, id: :term]},
    {RetractOapply, :retract_oapply, [object: :term, head: :term]},
    {RetractSlots, :retract_slots, [object: :term, slots: :term]},
    {SendAsync, :send_async, [object: :term, method: :term, args: :term]},
    {SendElixir, :send_elixir, [pid: :term, message: :term]},
    {GetClass, :get_class, [object: :term, class: :term]},
    {GetSuper, :get_super, [object: :term, super: :term]},
    {GetMethod, :get_method, [object: :term, name: :term, id: :term]},
    {GetOapply, :get_oapply, [object: :term, seq: :term, head: :term, body: :term]},
    {AssertValidClauseSelf, :assert_valid_clause_self, [class: :term, head: :term]},
    {OApply, :oapply, [method_id: :term, args: :term]},
    {Implies, :implies, [condition: :goals, then: :goals, otherwise: :goals]},
    {Or, :or, [or: :goals, then: :goals]},
    {Then, :then, [then: :goals]},
    {Forall, :forall, [condition: :goals, body: :goals]},
    {Findall, :findall, [template: :term, condition: :goals, result: :term]},
    {GetSlots, :get_slot, [object: :term, key: :term, value: :term]},
    {Gensym, :gensym, [var: :term]},
    {Print, :print, [pattern: :term]},
    {Not, :not, [condition: :goals]},
    {Unify, :unify, [a: :term, b: :term]},
    {Equal, :equal, [a: :term, b: :term]},
    {Compare, :compare, [op: :term, a: :term, b: :term]},
    {Either, :either, [left: :term, right: :term]},
    {Ground, :ground, [term: :term]},
    {IsVar, :var, [term: :term]},
    {Freeze, :freeze, [var: :term, goals: :goals]},
    {Call, :call, [head: :term, body: :goals, args: :term]},
    {Send, :send, [object: :term, method: :term, args: :term]},
    {SendQuery, :send_query, [object: :term, method: :term, args: :term]},
    {CallNextMethod, :call_next_method, [self: :term, args: :term]}
  ]

  @to_form Map.new(@forms, fn {mod, tag, fields} -> {mod, {tag, fields}} end)
  @from_form Map.new(@forms, fn {mod, tag, fields} -> {tag, {mod, fields}} end)

  @doc "Serialize one goal struct to its stored tuple form."
  @spec to_stored(t()) :: tuple() | atom()
  def to_stored(%Cut{}), do: :cut
  def to_stored(%Fail{}), do: :fail

  def to_stored(goal) when is_struct(goal) do
    case Map.fetch(@to_form, goal.__struct__) do
      {:ok, {tag, fields}} ->
        List.to_tuple([
          tag | Enum.map(fields, fn {name, kind} -> store(kind, Map.fetch!(goal, name)) end)
        ])

      :error ->
        goal
    end
  end

  # Cons by hand: patterns like [row | tail] are improper lists.
  def to_stored([h | t]), do: [to_stored(h) | to_stored(t)]
  def to_stored(other), do: other

  # `:term` slots may still nest goal structs (e.g. arithmetic in an `is`/`oapply`
  # arg list); recurse so nothing struct-shaped reaches storage.
  defp store(:term, v), do: to_stored(v)
  defp store(:goals, gs) when is_list(gs), do: Enum.map(gs, &to_stored/1)
  defp store(:goals, other), do: other

  @doc "Rebuild a goal struct from its stored tuple form (inverse of to_stored/1)."
  @spec from_stored(tuple() | atom()) :: t()
  def from_stored(:cut), do: %Cut{}
  def from_stored(:fail), do: %Fail{}

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
