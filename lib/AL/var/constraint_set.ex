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

  # A pending `vm_super(y, z)` with both sides open (`AL.Relations.GetSuper`)
  # posts one of these on each side instead of scanning -- `super/2`'s two
  # slots are the *same* domain (a superclass is still just a class), unlike
  # `class/2`'s object/class asymmetry, so a plain `isa`-style entry would be
  # a category error either way round (neither slot is "an instance of" the
  # other -- that's a different relation, subclass-of vs instance-of). The
  # tag records which slot the var carrying it occupies, so labeling either
  # one can reconstruct the correct `GetSuper{object:, super:}` goal.
  @type super_link() :: {:object, AL.Var.t()} | {:super, AL.Var.t()}

  @type t() :: %__MODULE__{
          dif: [{AL.Var.t(), AL.Var.t()}],
          isa: MapSet.t(atom()),
          bounds: {bound(), bound()},
          props: [propagator()],
          domain: MapSet.t(AL.Var.t()) | nil,
          super_link: super_link() | nil
        }

  defstruct dif: [],
            isa: MapSet.new(),
            bounds: {nil, nil},
            props: [],
            domain: nil,
            super_link: nil
end
