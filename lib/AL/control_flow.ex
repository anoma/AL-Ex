defmodule AL.ControlFlow do
  @moduledoc """
  I resolve the choicepoint-stack control-flow goals — `Cut`, `Implies`,
  `Or`, `Then` — the ones whose job is entirely about which alternatives
  stay on `state.choicepoint_stack`, not about producing a binding. See
  "Execution model: choicepoints, marks, cut" in the `al` skill for what
  `{:mark, scope}`/`:implies_mark` mean and why `cut`/`Then` drop the stack
  down to one.
  """

  alias AL.Goal

  def interp(%Goal.Cut{}, state) do
    %AL{
      state
      | active_choicepoint: state.active_choicepoint,
        choicepoint_stack:
          Enum.drop_while(state.choicepoint_stack, fn choice ->
            case choice do
              {:mark, f} ->
                f != state.active_choicepoint.scope_pointer

              _choice ->
                true
            end
          end)
    }
  end

  def interp(%Goal.Implies{condition: condition, then: then, otherwise: otherwise}, state) do
    spliced_condition = AL.splice_goals(state, condition ++ [%Goal.Then{then: then}])
    spliced_otherwise = AL.splice_goals(state, otherwise)

    %AL{
      state
      | active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | goals: spliced_condition
        },
        choicepoint_stack:
          [
            %AL.Choicepoint{
              state.active_choicepoint
              | goals: spliced_otherwise
            }
          ] ++
            [:implies_mark | state.choicepoint_stack]
    }
  end

  def interp(%Goal.Or{or: left, then: right}, state) do
    spliced_left = AL.splice_goals(state, left)
    spliced_right = AL.splice_goals(state, right)

    %AL{
      state
      | active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | goals: spliced_left
        },
        choicepoint_stack:
          [
            %AL.Choicepoint{
              state.active_choicepoint
              | goals: spliced_right
            }
          ] ++
            state.choicepoint_stack
    }
  end

  def interp(%Goal.Then{then: then}, state) do
    spliced_goals = AL.splice_goals(state, then)

    %AL{
      state
      | active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | goals: spliced_goals
        },
        choicepoint_stack:
          tl(
            Enum.drop_while(state.choicepoint_stack, fn choice ->
              case choice do
                :implies_mark -> false
                _choice -> true
              end
            end)
          )
    }
  end
end
