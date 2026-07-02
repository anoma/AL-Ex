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
          | Call.t()
          | Send.t()
          | SendQuery.t()
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

  typedstruct enforce: true, module: Fail do
  end

  # --- generic goal traversal: shape-preserving map / fold over leaves ---

  @doc "Transform every leaf of a goal term with `fun`."
  @spec map(term(), (term() -> term())) :: term()
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
  def reduce([], acc, _fun), do: acc
  def reduce([head | tail], acc, fun), do: reduce(tail, reduce(head, acc, fun), fun)

  def reduce(term, acc, fun) when is_struct(term),
    do: Enum.reduce(Map.from_struct(term), acc, fn {_k, v}, a -> reduce(v, a, fun) end)

  def reduce(term, acc, fun) when is_map(term),
    do: Enum.reduce(term, acc, fn {k, v}, a -> reduce(v, reduce(k, a, fun), fun) end)

  def reduce(term, acc, fun) when is_tuple(term),
    do: term |> Tuple.to_list() |> reduce(acc, fun)

  def reduce(leaf, acc, fun), do: fun.(leaf, acc)
end
