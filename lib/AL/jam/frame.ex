defmodule AL.JAM.Frame do
  @moduledoc "A suspended JAM execution with its registers, return frames, bindings, and pending goals."

  @enforce_keys [:id, :code, :slots]
  defstruct [:id, :code, :slots, pc: 0, returns: [], store: nil, pending: %{}]

  @type t :: %__MODULE__{
          id: term(),
          code: tuple(),
          pc: non_neg_integer(),
          slots: tuple(),
          returns: list(),
          store: AL.Var.store() | nil,
          pending: map()
        }
end
