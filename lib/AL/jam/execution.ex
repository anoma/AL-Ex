defmodule AL.JAM.Execution do
  @enforce_keys [:branch, :budget]
  defstruct [:branch, :budget, choices: [], targets: %{}, steps: 0, state: nil]

  @type t :: %__MODULE__{
          branch: AL.Branch.t(),
          budget: integer(),
          choices: [AL.JAM.State.stack_entry()],
          targets: map(),
          steps: non_neg_integer(),
          state: AL.JAM.State.t() | nil
        }
end
