defmodule AL.Trace.Runtime do
  @moduledoc """
  I hold ephemeral tracing machinery needed while an evaluation can continue.
  I am not part of the retained event model.
  """

  use TypedStruct

  @type scope() :: AL.scope()
  @type scope_info() :: %{
          parent: scope() | nil,
          kind: :method | :clause,
          open_vars: [term()],
          exited: boolean(),
          derived: %{optional(term()) => AL.Trace.Domino.var_description()} | nil
        }
  @type pending_constraint() :: %{
          goal: AL.Goal.t(),
          vars: MapSet.t(term()),
          constraints_in: %{optional(term()) => AL.Trace.Domino.var_description()}
        }

  typedstruct enforce: true do
    field(:tracepoints, MapSet.t(), default: MapSet.new())
    field(:traced_calls, %{optional(scope()) => tuple()}, default: %{})
    field(:scopes, %{optional(scope()) => scope_info()}, default: %{})
    field(:pending_constraint, pending_constraint() | nil, default: nil)
  end
end
