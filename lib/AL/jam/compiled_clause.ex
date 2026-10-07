defmodule AL.JAM.CompiledClause do
  @enforce_keys [:method, :sequence, :head, :head_operand, :matcher, :initial, :locals, :code]
  defstruct [
    :method,
    :sequence,
    :head,
    :head_operand,
    :matcher,
    :initial,
    :locals,
    :code,
    output_variants: %{},
    head_returns: %{}
  ]

  @type t :: %__MODULE__{
          method: term(),
          sequence: non_neg_integer(),
          head: term(),
          head_operand: term(),
          matcher: term(),
          initial: tuple(),
          locals: [{non_neg_integer(), AL.Var.t()}],
          code: tuple(),
          output_variants: map(),
          head_returns: map()
        }
end
