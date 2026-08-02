defmodule Examples.ALDomainLabel do
  @moduledoc """
  I provide examples for symbolic label domains: the same CLP(FD) sense in
  which `:number` advertises a numeric interval `vm_label` can enumerate, a
  user class can advertise its own finite domain via a `:domain` method —
  no VM special case, `:domain` is an ordinary `defmethod`. `vm_label`
  reaches it through `Goal.SendAsValue` (the same class-seeded lookup value
  dispatch itself uses), not by sending to the bare class atom — `:suit`'s
  own class is `:class`, so `method_scopes` drops it from its own search,
  the same rule that keeps a category from answering its own imported
  methods. `:domain`'s candidates only stick if the class also proves
  membership via literal per-value clause heads (`value_member?`) — the
  same shape `:letter_chain` already uses; `:domain` supplies what to try,
  it doesn't grant membership on its own.

  No class here needs its own `:init` override — `:value`'s own default
  now tags `output` with `vm_class` (`self`'s own `:class` scaffold field
  names it) before falling open, so `new(:suit, _, s)` isa-tags `s` for
  free, the same as generative dispatch already does externally when an
  open var reaches a class through `send` instead of `new` — one
  mechanism, not two.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example symbolic_domain_labels_via_class_and_vm_label() do
    {:atomic, _} =
      run branch: :examples do
        new(:class, %{name: :suit, super: :value, ivars: []}, _)

        defmethod(:suit, :domain, [self, [:hearts, :diamonds, :clubs, :spades]])

        defmethod(:suit, :hearts, [:hearts])
        defmethod(:suit, :diamonds, [:diamonds])
        defmethod(:suit, :clubs, [:clubs])
        defmethod(:suit, :spades, [:spades])
      end

    {:atomic, {bindings, state}} =
      run branch: :examples do
        new(:suit, _, s)
        vm_label(s)
      end

    assert Map.get(bindings, :"$s") == :hearts

    {:atomic, {bindings2, _}} = next_solution(state)
    assert Map.get(bindings2, :"$s") == :diamonds

    :ok
  end

  # Real backtracking, cheapest-first, not an eager `fan_out` — same
  # guarantee `vm_label`'s numeric-interval leg already gives (via
  # `between/4`), now for a symbolic domain too, via `member/2`. Its own
  # class (not a reuse of :suit above) — examples aren't guaranteed to run
  # in declaration order, so nothing here can depend on a sibling example
  # having already set anything up (same reason e_AL_categories.ex's
  # examples each build their own category from scratch).
  example symbolic_domain_enumerates_all_candidates_in_order() do
    {:atomic, _} =
      run branch: :examples do
        new(:class, %{name: :rank, super: :value, ivars: []}, _)

        defmethod(:rank, :domain, [self, [:jack, :queen, :king, :ace]])

        defmethod(:rank, :jack, [:jack])
        defmethod(:rank, :queen, [:queen])
        defmethod(:rank, :king, [:king])
        defmethod(:rank, :ace, [:ace])
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        findall(v, [new(:rank, _, v), vm_label(v)], ranks)
      end

    assert Map.get(bindings, :"$ranks") == [:jack, :queen, :king, :ace]
    :ok
  end

  # `:domain`'s candidates only stick if the class also proves membership —
  # a class that advertises a domain but has no matching per-value clause
  # heads for it fails at bind time, the same isa protection every other
  # value class gets, not a special exemption for domain-sourced candidates.
  example symbolic_domain_without_membership_evidence_still_fails() do
    {:atomic, _} =
      run branch: :examples do
        new(:class, %{name: :unprovable, super: :value, ivars: []}, _)
        defmethod(:unprovable, :domain, [self, [:a, :b]])
      end

    {:aborted, _trace} =
      run branch: :examples do
        new(:unprovable, _, v)
        vm_label(v)
      end

    :ok
  end

  # No isa at all, and no numeric bounds either — same "unbounded domain
  # fails" outcome `label_fails_on_an_unbounded_domain` (e_AL_bounds.ex)
  # shows for the numeric case, now for the general one.
  example label_without_isa_or_bounds_still_fails() do
    {:aborted, _trace} =
      run branch: :examples do
        vm_label(v)
      end

    :ok
  end

  # A slot can hold a genuinely open var, not an unresolved-but-bounded
  # one — `get_slot`'s own output is still fully open right after
  # construction (fails `vm_ground`, not just "not yet labeled"). `:card`'s
  # own `:init` constructs each slot via `new(:card_rank, _, r)` /
  # `new(:card_suit, _, s)` — not `vm_class` directly — so it's built on
  # `:card_rank`/`:card_suit`'s own construction contract (isa-tagging,
  # from `:value`'s shared `:init`) rather than reaching around it; if
  # either enum ever grew real construction logic later, `:card` would
  # stay correct automatically. A caller never needs to know/repeat which
  # class a card's own slots are typed as — `new(:card, ...)` alone is
  # enough to make them vm_label-able.
  example card_slot_stays_undetermined_until_constrained_and_labeled() do
    {:atomic, _} =
      run branch: :examples do
        new(:class, %{name: :card_rank, super: :value, ivars: []}, _)

        defmethod(:card_rank, :domain, [self, [:jack, :queen, :king, :ace]])

        defmethod(:card_rank, :jack, [:jack])
        defmethod(:card_rank, :queen, [:queen])
        defmethod(:card_rank, :king, [:king])
        defmethod(:card_rank, :ace, [:ace])

        new(:class, %{name: :card_suit, super: :value, ivars: []}, _)

        defmethod(:card_suit, :domain, [self, [:hearts, :diamonds, :clubs, :spades]])

        defmethod(:card_suit, :hearts, [:hearts])
        defmethod(:card_suit, :diamonds, [:diamonds])
        defmethod(:card_suit, :clubs, [:clubs])
        defmethod(:card_suit, :spades, [:spades])

        new(:class, %{name: :card, super: :value, ivars: [:rank, :suit]}, _)

        defmethod(:card, :get_slot, [self, k, v]) do
          vm_map_get(self, k, v)
        end

        defmethod(:card, :init, [self, _args, new]) do
          new(:card_rank, _, r)
          new(:card_suit, _, s)
          unify(new, %{class: :card, rank: r, suit: s})
        end
      end

    {:aborted, _trace} =
      run branch: :examples do
        new(:card, %{}, c)
        get_slot(c, :rank, r)
        vm_ground(r)
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:card, %{}, c)
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

  # `dif` between two still-open slots (not two already-decided values) —
  # the second card's rank has to skip whatever the first one labeled to,
  # the same reactive discipline every other constraint in AL.Var.bind
  # gets, no special case for cards. Its own class (`:dealt_card`, not a
  # reuse of `:card` above) — two examples both naming a class `:card` but
  # giving it *different* `:init` bodies would silently race: clause
  # accretion means whichever declaration runs first wins for both
  # (`:init`'s own `new` argument is always open, so the first clause tried
  # always matches), and examples aren't guaranteed to run in declaration
  # order.
  example two_cards_constrained_never_equal_via_dif() do
    {:atomic, _} =
      run branch: :examples do
        new(:class, %{name: :card_rank, super: :value, ivars: []}, _)

        defmethod(:card_rank, :domain, [self, [:jack, :queen, :king, :ace]])

        defmethod(:card_rank, :jack, [:jack])
        defmethod(:card_rank, :queen, [:queen])
        defmethod(:card_rank, :king, [:king])
        defmethod(:card_rank, :ace, [:ace])

        new(:class, %{name: :dealt_card, super: :value, ivars: [:rank]}, _)

        defmethod(:dealt_card, :get_slot, [self, k, v]) do
          vm_map_get(self, k, v)
        end

        defmethod(:dealt_card, :init, [self, _args, new]) do
          new(:card_rank, _, r)
          unify(new, %{class: :dealt_card, rank: r})
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:dealt_card, %{}, c1)
        new(:dealt_card, %{}, c2)
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
