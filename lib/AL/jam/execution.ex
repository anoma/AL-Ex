defmodule AL.JAM.Execution do
  @enforce_keys [:branch, :budget]
  defstruct [:branch, :budget, choices: [], targets: %{}, steps: 0]

  @type t :: %__MODULE__{
          branch: AL.Branch.t(),
          budget: integer(),
          choices: list(),
          targets: map(),
          steps: non_neg_integer()
        }
end
