defmodule AL.Choicepoint do
  use TypedStruct

  typedstruct enforce: true do
    field(:progress, non_neg_integer(), default: 0)
    field(:store, AL.Var.store() | nil, enforce: true, default: %{})
    field(:scope_pointer, AL.JAM.State.scope(), enforce: true, default: 0)
  end
end
