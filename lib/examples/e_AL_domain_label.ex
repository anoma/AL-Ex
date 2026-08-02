defmodule Examples.ALDomainLabel do
  @moduledoc """
  Symbolic label domains: a user class advertises a finite domain via an
  ordinary `:domain` defmethod, no VM special case. `vm_label` reaches it
  via `Goal.SendAsValue`, not the bare class atom (method_scopes drops a
  class from its own search). `:domain` only supplies candidates -- the
  class still has to prove membership via its own per-value clause heads.

  No class here needs its own `:init` -- `:value`'s default already tags
  `output` via `vm_class`, so `new(:suit, s)` isa-tags `s` for free.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example symbolic_domain_labels_via_class_and_vm_label() do
    {:atomic, _} =
      run branch: :examples do
        defclass :suit, super: :value do
          defmethod(:domain, [self, [:hearts, :diamonds, :clubs, :spades]]) do
          end

          defmethod(:hearts, [:hearts]) do
          end

          defmethod(:diamonds, [:diamonds]) do
          end

          defmethod(:clubs, [:clubs]) do
          end

          defmethod(:spades, [:spades]) do
          end
        end
      end

    {:atomic, {bindings, state}} =
      run branch: :examples do
        new(:suit, s)
        vm_label(s)
      end

    assert Map.get(bindings, :"$s") == :hearts

    {:atomic, {bindings2, _}} = next_solution(state)
    assert Map.get(bindings2, :"$s") == :diamonds

    :ok
  end

  # real backtracking via member/2, not an eager fan_out -- same guarantee
  # vm_label's numeric leg gives via between/4. Own class, not a reuse of
  # :suit -- examples aren't guaranteed to run in declaration order.
  example symbolic_domain_enumerates_all_candidates_in_order() do
    {:atomic, _} =
      run branch: :examples do
        defclass :rank, super: :value do
          defmethod(:domain, [self, [:jack, :queen, :king, :ace]]) do
          end

          defmethod(:jack, [:jack]) do
          end

          defmethod(:queen, [:queen]) do
          end

          defmethod(:king, [:king]) do
          end

          defmethod(:ace, [:ace]) do
          end
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        findall(v, [new(:rank, v), vm_label(v)], ranks)
      end

    assert Map.get(bindings, :"$ranks") == [:jack, :queen, :king, :ace]
    :ok
  end

  # domain candidates only stick if the class also proves membership -- no
  # matching per-value clause head, fails at bind time like any value class.
  example symbolic_domain_without_membership_evidence_still_fails() do
    {:atomic, _} =
      run branch: :examples do
        defclass :unprovable, super: :value do
          defmethod(:domain, [self, [:a, :b]]) do
          end
        end
      end

    {:aborted, _trace} =
      run branch: :examples do
        new(:unprovable, v)
        vm_label(v)
      end

    :ok
  end

  # no isa, no numeric bounds -- same "unbounded domain fails" outcome as
  # the numeric case (e_AL_bounds.ex).
  example label_without_isa_or_bounds_still_fails() do
    {:aborted, _trace} =
      run branch: :examples do
        vm_label(v)
      end

    :ok
  end

  # a slot holds a genuinely open var right after construction (fails
  # vm_ground, not just "not yet labeled"). card's :init builds each slot
  # via new(:card_rank, r) / new(:card_suit, s), not vm_class directly --
  # rides the enum's own construction contract instead of reaching around it.
  example card_slot_stays_undetermined_until_constrained_and_labeled() do
    {:atomic, _} =
      run branch: :examples do
        defclass :card_rank, super: :value do
          defmethod(:domain, [self, [:jack, :queen, :king, :ace]]) do
          end

          defmethod(:jack, [:jack]) do
          end

          defmethod(:queen, [:queen]) do
          end

          defmethod(:king, [:king]) do
          end

          defmethod(:ace, [:ace]) do
          end
        end

        defclass :card_suit, super: :value do
          defmethod(:domain, [self, [:hearts, :diamonds, :clubs, :spades]]) do
          end

          defmethod(:hearts, [:hearts]) do
          end

          defmethod(:diamonds, [:diamonds]) do
          end

          defmethod(:clubs, [:clubs]) do
          end

          defmethod(:spades, [:spades]) do
          end
        end

        defclass :card, super: :value, ivars: [:rank, :suit] do
          defmethod(:get_slot, [self, k, v]) do
            vm_map_get(self, k, v)
          end

          defmethod(:init, [self, _args, new]) do
            new(:card_rank, r)
            new(:card_suit, s)
            unify(new, %{class: :card, rank: r, suit: s})
          end
        end
      end

    {:aborted, _trace} =
      run branch: :examples do
        new(:card, c)
        get_slot(c, :rank, r)
        vm_ground(r)
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:card, c)
        get_slot(c, :rank, r)
        get_slot(c, :suit, s)
        vm_label(r)
        vm_label(s)
      end

    assert Map.get(bindings, :"$r") == :jack
    assert Map.get(bindings, :"$s") == :hearts
    assert Map.get(bindings, :"$c") == %{class: :card, rank: :jack, suit: :hearts}

    :ok
  end

  # dif between two still-open slots -- second card's rank skips whatever
  # the first labeled to, ordinary AL.Var.bind reactivity, no card special
  # case. Own class :dealt_card, not a reuse of :card -- two examples
  # naming the same class with different :init bodies would silently race.
  example two_cards_constrained_never_equal_via_dif() do
    {:atomic, _} =
      run branch: :examples do
        defclass :card_rank, super: :value do
          defmethod(:domain, [self, [:jack, :queen, :king, :ace]]) do
          end

          defmethod(:jack, [:jack]) do
          end

          defmethod(:queen, [:queen]) do
          end

          defmethod(:king, [:king]) do
          end

          defmethod(:ace, [:ace]) do
          end
        end

        defclass :dealt_card, super: :value, ivars: [:rank] do
          defmethod(:get_slot, [self, k, v]) do
            vm_map_get(self, k, v)
          end

          defmethod(:init, [self, _args, new]) do
            new(:card_rank, r)
            unify(new, %{class: :dealt_card, rank: r})
          end
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:dealt_card, c1)
        new(:dealt_card, c2)
        get_slot(c1, :rank, r1)
        get_slot(c2, :rank, r2)
        dif(r1, r2)
        vm_label(r1)
        vm_label(r2)
      end

    assert Map.get(bindings, :"$r1") == :jack
    assert Map.get(bindings, :"$r2") == :queen

    :ok
  end
end
