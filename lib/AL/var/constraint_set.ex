defmodule AL.Var.ConstraintSet do
  @moduledoc """
  I am what a still-open var's store entry holds instead of a bound term — a
  struct, not a plain map, specifically so `AL.Var.deref/2` can tell "still
  open, here's what's known" apart from "bound to a term that happens to be a
  plain map" by shape alone: no AL-level term is ever a `%ConstraintSet{}` (AL
  values are atoms/numbers/binaries/lists/tuples/maps, never a tagged internal
  struct), so a bound entry needs no wrapper of its own — a bare bound term
  and this struct are already unambiguous by pattern match.
  """

  @type bound() :: integer() | nil
  @type propagator() :: AL.Var.Bounds.propagator()

  @type t() :: %__MODULE__{
          dif: [{AL.Var.t(), AL.Var.t()}],
          isa: MapSet.t(atom()),
          bounds: {bound(), bound()},
          props: [propagator()],
          domain: MapSet.t(AL.Var.t()) | nil
        }

  defstruct dif: [], isa: MapSet.new(), bounds: {nil, nil}, props: [], domain: nil
end
