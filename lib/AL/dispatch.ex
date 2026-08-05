defmodule AL.Dispatch do
  @moduledoc """
  Resolves a `send` into a method application.

  Ground receiver+selector -> `do_send/5`. Open receiver -> query: enumerate
  `:value` candidates (`generative_candidate/5` — calls class's own `new`,
  whose `init` discards the constructed scaffold, so self comes back
  exactly as open as it started; a class's own clauses then unify against
  it directly or run whatever relational construction logic they define
  with self still open, e.g. `:mapset_value`'s `list_to_elems`), plus durable (a
  real scan, deferred behind a placeholder until backtracking reaches it,
  `force_durable_candidates/4`). `isa` attaches to each candidate's
  choicepoint before its goals run; each candidate is its own choicepoint.
  Open selector -> enumerate self's own method names
  (`enumerate_selectors/4`), re-dispatch per name. Both ground -> `do_send/5`
  runs the first matching provider (`run_providers/6`); miss -> DNU
  (directed) or backtrack (query).
  """

  alias AL.Goal

  @primitive_methods [:is, :map_get, :map_put, :gensym, :fresh_id]

  # A var receiver or selector makes the send a query: enumerate candidates, ground
  # the hole, re-dispatch as a query (misses backtrack, not DNU). Only a fully ground
  # send is directed and uses `on_miss`. `:"$_"` is the wildcard, not a hole.
  def dispatch(self, method, args, state, on_miss) do
    {state, method_scope, on_miss} = AL.begin_method_scope(state, self, method, args, on_miss)

    cond do
      AL.Var.var?(self) and self != :"$_" ->
        known_isa = AL.Var.isa_of(state.active_choicepoint.store, self)

        value_classes =
          state.branch
          |> generative_descendants()
          |> filter_by_selector(method, state.branch)
          |> Enum.reject(&isa_conflict?(known_isa, &1, state.branch))

        maybe_trace_dispatch(state, self, method, value_classes)

        candidates =
          Enum.map(value_classes, &generative_candidate(state, self, method, args, &1)) ++
            [durable_placeholder(state, self, method, args)]

        install_method_choicepoints(state, method_scope, candidates)

      AL.Var.var?(method) and method != :"$_" ->
        enumerate_selectors(self, method, args, state, method_scope)

      true ->
        do_send(self, method, args, method_scope, state, on_miss)
    end
  end

  # An object is single-classed, period -- the same invariant `AL.Store`'s
  # `SetClass` already enforces for a durable atom's direct class. Two
  # distinct classes on the same var only coexist when one is an ancestor of
  # the other (real inheritance, not a coincidence): `:number`/`:list`/`:map`
  # can't overlap, no two unrelated `super: :value` classes can (`:card` vs
  # `:number`), and neither can a value class and an unrelated durable one
  # (`:number` vs `:package`) -- there's no special "exclusive" subset, every
  # class is exclusive of every other unrelated class. Used both to filter
  # which candidates dispatch offers (here) and by `GetClass`'s
  # no-witness-needed isa fast path (`AL.Relations`), which used to be able to
  # union in a conflicting class with no check at all.
  #
  # An isa entry that's still an open var (`class(x, y)` with both sides
  # open posts `y` onto `x`) hasn't resolved to a class yet, so it can't
  # conflict with anything -- a var is a superset of any atom until it
  # resolves, not a competing class. Same for `{:object_link, _}` (posted on
  # the *class* side of that same pending `class` -- see
  # `AL.Relations.GetClass`): it's a directional marker, never a class atom,
  # so `not AL.Var.var?/1` alone would wrongly treat it as one (a 2-tuple
  # isn't a var, but it isn't a resolved class either). Only a genuinely
  # resolved atom -- not a var, not a link marker -- ever gets the real
  # `related?` check.
  @spec isa_conflict?(Enumerable.t(atom()), atom(), AL.Branch.t()) :: boolean()
  def isa_conflict?(known_isa, class, branch) do
    Enum.any?(known_isa, fn existing ->
      resolved_isa_class?(existing) and existing != class and
        not related?(class, existing, branch)
    end)
  end

  defp resolved_isa_class?(existing), do: is_atom(existing) and not AL.Var.var?(existing)

  defp related?(a, b, branch) do
    b in AL.Dispatch.MethodOrder.super_chain([a], branch, :dfs) or
      a in AL.Dispatch.MethodOrder.super_chain([b], branch, :dfs)
  end

  # method must be ground to check tracepoints — a var selector has nothing
  # to look up yet.
  defp maybe_trace_dispatch(state, self, method, value_classes) do
    if not AL.Var.var?(method) and MapSet.member?(state.domino.tracepoints, method) do
      AL.Trace.dispatch(self, method, value_classes)
    end
  end

  # Offers self = shape as one hypothesis, re-querying once grounded. Shared
  # by force_durable_candidates/4 (a send's own durable leg, wrapping each
  # real object as a candidate) and durable_witness/5 (Goal.Label's
  # isa-fallback leg, below) -- both eagerly unify self against a concrete
  # shape (a real object id either way), differing only in what goals run
  # afterward.
  defp durable_choicepoint(state, self, shape, goals) do
    new_store = AL.Var.unify(self, shape, state.active_choicepoint.store, state.branch)

    %AL.Choicepoint{
      state.active_choicepoint
      | goals: goals,
        store: new_store
    }
  end

  # Shared between both legs: which requery a candidate needs is purely
  # "is self still open once its own construction goals have actually run" —
  # not which leg produced the candidate. Durable's own unify (in
  # structural_candidate, above) is eager, so self is already ground by the
  # time this splices in; generative's isn't (new/init hasn't run yet at
  # splice time, so whether self stays open depends on that class's own
  # init), so the check has to be a goal that runs *after* construction, not
  # an Elixir-level branch decided up front. One Implies/IsVar fragment
  # covers both — for durable it's a no-op (the condition is already
  # settled), for generative it's the actual decision.
  defp requery_goals(self, class, method, args) do
    [
      %Goal.Implies{
        condition: [%Goal.IsVar{term: self}],
        then: [%Goal.SendAsValue{class: class, object: self, method: method, args: args}],
        otherwise: [%Goal.SendQuery{object: self, method: method, args: args}]
      }
    ]
  end

  # Only called for :value classes (dispatch/5's only generative leg — see
  # moduledoc). Attaches isa at construction (live for the whole call, not
  # just future binds — see al-clp-for-objects memory), then calls class's
  # own new with a fresh var per declared ivar; :value's own init
  # (bootstrap.ex) discards the scaffold, so self stays open for
  # send_as_value to unify against class's own clause heads directly (sound
  # only when clause heads fully spec an instance — super: :value opts in).
  defp generative_candidate(state, self, method, args, class),
    do: generative_choicepoint(state, self, class, requery_goals(self, class, method, args))

  # Shared by generative_candidate/5 (a send's own generative leg) and
  # generative_witness/4 (Goal.Label's isa-fallback leg, below) -- both
  # construct a fresh instance via witness_goals/3 and attach isa at
  # construction, differing only in what extra goals run afterward (a
  # requery for the send's own method, vs pending-link unifications for a
  # bare label with no selector in hand).
  defp generative_choicepoint(state, self, class, extra_goals) do
    goals = AL.splice_goals(state, witness_goals(state, self, class) ++ extra_goals)

    %AL.Choicepoint{
      state.active_choicepoint
      | goals: goals,
        store: AL.Var.add_isa(state.active_choicepoint.store, self, class)
    }
  end

  # The part of `generative_candidate/5` that has nothing to do with which
  # method was asked for: call the class's own `new` with a fresh var per
  # declared ivar, unify `self` against whatever it builds. Shared with
  # `witness_choicepoints/3` (below), which needs exactly this and nothing
  # else — labeling an isa-constrained var has no selector in hand at all.
  defp witness_goals(state, self, class) do
    scope = AL.fresh_scope()
    shape = AL.Var.var("candidate_shape_#{scope}")

    fresh_args =
      Map.new(class_ivars(class, state.branch), fn ivar ->
        name = ivar_name(ivar)
        {name, AL.Var.var("candidate_ivar_#{name}_#{scope}")}
      end)

    [
      %Goal.Send{object: class, method: :new, args: [fresh_args, shape]},
      %Goal.Unify{a: self, b: shape}
    ]
  end

  # `class/2` is a typed relation over two different domains, the same way
  # `parent(X, Y)` ranges over "people" in both positions but *means*
  # something different per slot -- position 1 ranges over objects,
  # position 2 over classes, and forcing a var open means something
  # different depending which slot it's standing in. An isa entry records
  # which slot a var plays: a bare class atom/still-open var means "I'm an
  # object, this is my class" (`object_witness_choicepoints/4` below); an
  # `{:object_link, x}` marker means "I'm a class, `x` is my object"
  # (`class_domain_choicepoints/3`). Both are `Goal.Label`'s fallback for an
  # isa-constrained var with no numeric bounds/`in_domain` set, and both are
  # exactly what `send` dispatch already forces implicitly on an open
  # receiver -- labeling is the same forcing with no method in mind.

  # The object slot: reuses the exact construction dispatch already runs
  # for a var receiver -- one choicepoint per candidate class (construction
  # only, no method to run after) plus one per matching durable object.
  # `candidate_classes` is `:any` when nothing is known yet (`class(x,
  # y)` posted a pending link, no filter to narrow by) or a concrete list
  # once isa has narrowed it; `pending_links` are extra vars (`y`, when
  # still open) that also get unified to the class a candidate turns out to
  # be, so the far end of a pending link resolves too. No compatibility
  # check needed beyond the cheap membership filter below: whichever
  # candidate gets tried still unifies `self` through `AL.Var.bind`, which
  # validates against *every* constraint already on `self` -- a candidate
  # that only satisfies part of a multi-class isa (e.g. an ancestor's own
  # `new` when a more specific descendant is also required) simply fails
  # there and backtracking moves on, the same way any other wrong candidate
  # already does.
  @spec object_witness_choicepoints(AL.t(), AL.Var.t(), :any | [atom()], [AL.Var.t()]) ::
          [AL.Choicepoint.t()]
  def object_witness_choicepoints(state, self, candidate_classes, pending_links \\ []) do
    generative_classes =
      case candidate_classes do
        :any -> generative_descendants(state.branch)
        list -> Enum.filter(list, &(&1 in generative_descendants(state.branch)))
      end

    generative = Enum.map(generative_classes, &generative_witness(state, self, &1, pending_links))

    durable =
      state.branch
      |> durable_classes()
      |> Enum.flat_map(fn {object, obj_classes} ->
        obj_classes
        |> Enum.filter(&candidate_class?(candidate_classes, &1))
        |> Enum.map(&durable_witness(state, self, object, &1, pending_links))
      end)
      |> Enum.reject(&(&1.store == nil))

    generative ++ durable
  end

  defp candidate_class?(:any, _class), do: true
  defp candidate_class?(list, class), do: class in list

  defp generative_witness(state, self, class, pending_links) do
    extra = Enum.map(pending_links, &%Goal.Unify{a: &1, b: class})
    generative_choicepoint(state, self, class, extra)
  end

  # No requery, no method -- self is already unified to a real object, so
  # there's nothing left to run beyond any pending links.
  defp durable_witness(state, self, object, class, pending_links) do
    extra = Enum.map(pending_links, &%Goal.Unify{a: &1, b: class})
    durable_choicepoint(state, self, object, AL.splice_goals(state, extra))
  end

  # The class slot (`{:object_link, x}`, posted on the *class* position of a
  # still-open `class(x, y)` -- see `AL.Relations.GetClass`) is a
  # fundamentally different labeling question than the object slot: an
  # object needs a real witness constructed or found; a class already
  # exists as a declared entity, so labeling one just needs to name it, not
  # construct anything -- reusing `object_witness_choicepoints/4` here would
  # wrongly force a concrete instance of `x` into existence just to name
  # `x`'s class. So this enumerates every class in the system (every
  # generative descendant, every class that already classifies some durable
  # object) and, for each, splices `GetClass`'s *own* branch-1 goal
  # (`class(x, class)`) rather than re-deriving its isa-conflict check
  # here -- a conflicting candidate simply fails when its spliced goal runs,
  # same as any other wrong choicepoint, not something pre-filtered before
  # the choicepoint exists. A class with zero existing instances still gets
  # listed by name; `x` ends up isa-tagged and open, not witnessed --
  # ordinary `GetClass` branch-1 semantics, same as `class(x,
  # :known_class)` alone always leaves it.
  @spec class_domain_choicepoints(AL.t(), AL.Var.t(), AL.Var.t()) :: [AL.Choicepoint.t()]
  def class_domain_choicepoints(state, self, object_var) do
    every_class(state.branch)
    |> Enum.map(&class_domain_witness(state, self, object_var, &1))
  end

  defp every_class(branch) do
    durable = branch |> durable_classes() |> Enum.flat_map(fn {_object, classes} -> classes end)
    Enum.uniq(generative_descendants(branch) ++ durable)
  end

  defp class_domain_witness(state, self, object_var, class) do
    goals =
      AL.splice_goals(state, [
        %Goal.GetClass{object: object_var, class: class},
        %Goal.Unify{a: self, b: class}
      ])

    %AL.Choicepoint{state.active_choicepoint | goals: goals}
  end

  # Deferred durable candidates. Scanning every durable object of a matching
  # class (`durable_candidates/2`) and building a choicepoint per one is real,
  # immediate work — a full table read — done whether or not backtracking ever
  # reaches this leg (e.g. the value leg matches first and the query never
  # needs another candidate; `cut` drops this leg's whole region of the stack
  # unentered). So dispatch pushes one cheap placeholder choicepoint instead
  # of the real candidates; force_durable_candidates/4 (called only once this
  # placeholder becomes active) does the scan and expands then, not before.
  defp durable_placeholder(state, self, method, args) do
    goals =
      AL.splice_goals(state, [%Goal.DurableCandidates{object: self, method: method, args: args}])

    %AL.Choicepoint{state.active_choicepoint | goals: goals}
  end

  @spec force_durable_candidates(AL.Var.t(), AL.Var.t(), AL.Var.t(), AL.t()) :: AL.t()
  def force_durable_candidates(self, method, args, state) do
    # `class` here is never actually read -- durable_choicepoint/4 unifies
    # self with a real, already-existing id before this ever runs, so the
    # IsVar check inside requery_goals/4 always takes the SendQuery branch.
    requery = AL.splice_goals(state, requery_goals(self, self, method, args))
    known_isa = AL.Var.isa_of(state.active_choicepoint.store, self)

    candidates =
      state.branch
      |> durable_candidates(method, known_isa)
      |> Enum.map(&durable_choicepoint(state, self, &1, requery))
      |> Enum.reject(&(&1.store == nil))

    install_choicepoints(state, candidates)
  end

  defp durable_candidates(branch, method, known_isa) do
    branch
    |> durable_object_class_pairs(known_isa)
    |> Enum.filter(fn {_object, classes} ->
      AL.Var.var?(method) or Enum.any?(classes, &answers_selector?(&1, method, branch))
    end)
    |> Enum.map(fn {object, _classes} -> object end)
  end

  # `known_isa` empty -- the common case, most sends have no isa constraint
  # posted on self before they dispatch -- means the same full, cached scan
  # as always. Non-empty: narrow to one indexed scan_class call per class in
  # the isa domain's *descendant* closure (isa is transitive, so a durable
  # object classed :dog still satisfies isa: [:animal]) instead of reading
  # every class row in the table and relying on the later bind-time isa
  # check alone to reject the ones that don't apply. `resolved_isa_class?/1`
  # (below) excludes anything not yet a real class atom (a still-open
  # pending-link var, or an `{:object_link, _}` marker) the same way
  # `isa_conflict?/3` already has to.
  defp durable_object_class_pairs(branch, known_isa) do
    case Enum.filter(known_isa, &resolved_isa_class?/1) do
      [] ->
        durable_classes(branch)

      classes ->
        classes
        |> Enum.flat_map(&AL.Dispatch.MethodOrder.descendants_of(&1, branch))
        |> Enum.uniq()
        |> Enum.flat_map(fn class ->
          AL.Object.scan_class(
            AL.Var.var("durable_narrow_scan_#{AL.fresh_scope()}"),
            class,
            branch
          )
        end)
        |> Enum.group_by(
          fn {:class, object, _seq, _class} -> object end,
          fn {:class, _o, _seq, class} -> class end
        )
        |> Map.to_list()
    end
  end

  # Every {object, classes} pair with a durable class row. Unbound self/class scan
  # (no key to bind), so cached per branch rather than rescanned per dispatch.
  # `def`, not `defp` -- `AL.Relations`'s `ClassInstances` also reads this (a
  # real witness scan for one specific class), so both share the one cached
  # scan rather than each paying for their own.
  def durable_classes(branch) do
    AL.ResolutionCache.fetch_durable_classes(branch, fn ->
      scope = AL.fresh_scope()

      AL.Object.scan_class(
        AL.Var.var("durable_scan_object_#{scope}"),
        AL.Var.var("durable_scan_class_#{scope}"),
        branch
      )
      |> Enum.group_by(
        fn {:class, object, _seq, _class} -> object end,
        fn {:class, _o, _seq, class} -> class end
      )
      |> Map.to_list()
    end)
  end

  # Ground selector: prune candidates that couldn't answer it before they're
  # even constructed (cheap, reuses method lookup) — keeps this from paying
  # for every value descendant on every open dispatch. Unbound selector:
  # nothing to check, every class stays a candidate.
  defp filter_by_selector(classes, method, branch) do
    if AL.Var.var?(method) do
      classes
    else
      Enum.filter(classes, &answers_selector?(&1, method, branch))
    end
  end

  defp answers_selector?(class, method, branch) do
    AL.ResolutionCache.fetch_providers(branch, {:answers, class, method}, fn ->
      Enum.any?(
        AL.Dispatch.MethodOrder.super_chain([class], branch, :dfs),
        &(method_ids(&1, method, branch) != [])
      )
    end)
  end

  # class's declared ivars, [] if never recorded.
  defp class_ivars(class, branch) do
    case AL.Object.read_slots(class, branch) do
      [{:slots, ^class, %{ivars: ivars}}] -> ivars
      _ -> []
    end
  end

  # An ivar is either a bare name or a {name, spec_opts} pair (ivar specs,
  # e.g. `suit: [domain: [...]]]`) -- always resolve to the bare name before
  # using it as a map key, or a spec'd ivar would key fresh_args by the whole
  # tuple instead of its name.
  defp ivar_name({name, _opts}), do: name
  defp ivar_name(name), do: name

  # Classes with :value as direct super. seq is per-object, no cross-class
  # ordering guarantee.
  defp generative_descendants(branch) do
    AL.ResolutionCache.fetch_generative_descendants(branch, fn ->
      scope = AL.fresh_scope()

      AL.Object.scan_super(AL.Var.var("value_scan_class_#{scope}"), :value, branch)
      |> Enum.map(fn {:super, class, _seq, :value} -> class end)
    end)
  end

  # term is provably a class instance: unifies with one of class's own clause
  # heads in the self position. Used by AL.Var.isa?/3 so an isa constraint
  # attached before a value candidate's match doesn't reject the class's own
  # defining clauses. Bare-variable self position excludes (proves nothing,
  # else vacuously true for anything).
  @spec value_member?(AL.Var.t(), atom(), AL.Branch.t()) :: boolean()
  def value_member?(term, class, branch) do
    class in generative_descendants(branch) and
      class
      |> own_clause_self_patterns(branch)
      |> Enum.any?(fn pattern ->
        not AL.Var.var?(pattern) and
          AL.Var.unify(AL.Var.freshen(pattern, Integer.to_string(AL.fresh_scope())), term) != nil
      end)
  end

  defp own_clause_self_patterns(class, branch) do
    for {:method, _o, _n, id} <-
          AL.Object.scan_method(class, :"$isa_check_name", :"$isa_check_id", branch),
        {:oapply, _id, _seq, [self_pattern | _], _body} <- AL.cached_scan_clauses(id, branch),
        do: self_pattern
  end

  # Shared "first candidate becomes active, the rest queue up behind it"
  # idiom for installing N already-built choicepoint alternatives -- used by
  # both dispatch legs (via dispatch/5 and force_durable_candidates/4) and
  # by Goal.Label's isa fallback (label_from_class_domain/3, AL.ex), so
  # there's exactly one way this happens anywhere in the codebase. Order is
  # try-order: `candidates`' own order is preserved (the first element is
  # tried first), not reversed -- unlike a LIFO push loop, this sets the
  # whole stack in one assignment, so there's no double-reversal to reason
  # about.
  @spec install_choicepoints(AL.t(), [AL.Choicepoint.t()]) :: AL.t()
  def install_choicepoints(state, candidates) do
    case candidates do
      [] ->
        AL.backtrack(state)

      [first | rest] ->
        %AL{state | active_choicepoint: first, choicepoint_stack: rest ++ state.choicepoint_stack}
    end
  end

  # Same idiom, but for a method-level (dispatch) candidate set rather than
  # a plain choicepoint list: appends `{:method_mark, method_scope}` below
  # every candidate, so backtrack/1 can tell "every provider for this send
  # exhausted" apart from "every alternative some unrelated caller pushed
  # exhausted" -- exactly what `{:mark, scope}` already does one level down,
  # for clauses. No retagging needed here: every candidate a caller passes
  # in is itself a struct-copy of `state.active_choicepoint`
  # (`generative_choicepoint`/`durable_choicepoint`/`enumerate_selectors`'s
  # own candidate builder), and `AL.begin_method_scope/5` already retagged
  # *that* to `method_scope` before any of them were built.
  @spec install_method_choicepoints(AL.t(), AL.scope(), [AL.Choicepoint.t()]) :: AL.t()
  def install_method_choicepoints(state, method_scope, candidates) do
    marked_stack = [{:method_mark, method_scope} | state.choicepoint_stack]

    case candidates do
      [] ->
        AL.backtrack(%AL{state | choicepoint_stack: marked_stack})

      [first | rest] ->
        %AL{state | active_choicepoint: first, choicepoint_stack: rest ++ marked_stack}
    end
  end

  # Bind the selector to each method `self` understands and re-dispatch as a query;
  # the call's arg shape selects which match.
  defp enumerate_selectors(self, method, args, state, method_scope) do
    case understood_method_names(self, state.branch) do
      [] ->
        install_method_choicepoints(state, method_scope, [])

      names ->
        spliced =
          AL.splice_goals(state, [%Goal.SendQuery{object: self, method: method, args: args}])

        candidate = fn name ->
          new_store = AL.Var.unify(method, name, state.active_choicepoint.store, state.branch)

          AL.wake(
            %AL.Choicepoint{state.active_choicepoint | goals: spliced, store: new_store},
            [method]
          )
        end

        install_method_choicepoints(state, method_scope, Enum.map(names, candidate))
    end
  end

  defp understood_method_names(self, branch) do
    AL.Dispatch.MethodOrder.method_scopes(self, branch)
    |> Enum.flat_map(fn scope ->
      for {:method, _o, name, _id} <- AL.Object.scan_method(scope, :"$name", :"$id", branch),
          do: name
    end)
    |> Enum.uniq()
  end

  defp do_send(self, method, args, method_scope, state, on_miss),
    do:
      run_providers(
        providers(self, method, state.branch),
        self,
        method,
        [self | args],
        method_scope,
        state,
        on_miss
      )

  # Like do_send, but scope chain is seeded from an explicit class, not
  # derived from self's shape (an unbound self has none to derive from).
  # self is constrained to class by the caller, not here.
  def do_send_as(class, self, method, args, state, on_miss) do
    {state, method_scope, on_miss} = AL.begin_method_scope(state, self, method, args, on_miss)

    candidates =
      providers_for(class, method, state.branch, fn ->
        AL.Dispatch.MethodOrder.super_chain([class], state.branch, :dfs)
      end)

    run_providers(candidates, self, method, [self | args], method_scope, state, on_miss)
  end

  # Run the first provider whose clause fits, stashing the rest -- plus the
  # method_scope of the send that started this whole resolution -- as a
  # cursor for `call_next_method` (AL.ex) to resume from, so a later
  # explicit next-provider request still reports against the *original*
  # method-level box rather than opening a fresh one. First match wins (a
  # clause mismatch stays a miss). Primitives make no frame, so carry no
  # cursor.
  def run_providers([], _self, _selector, _call_args, _method_scope, state, on_miss),
    do: on_miss.(state)

  def run_providers([{_scope, id} | rest], self, selector, call_args, method_scope, state, on_miss) do
    if has_matching_clause?(id, call_args, state.active_choicepoint.store, state.branch) do
      state =
        if id in @primitive_methods,
          do: state,
          else: %AL{state | pending_cursor: {self, selector, rest, method_scope}}

      AL.interp(%Goal.OApply{method_id: id, args: call_args}, state)
    else
      on_miss.(state)
    end
  end

  # Every {scope, id} answering selector across self's scopes. send takes the
  # head, call_next_method the tail. Cache key is resolution_key, not raw
  # self (method_scopes only depends on class, not the rest of the content).
  defp providers(self, selector, branch),
    do:
      providers_for(resolution_key(self), selector, branch, fn ->
        AL.Dispatch.MethodOrder.method_scopes(self, branch)
      end)

  # `scopes_fn` is a thunk, not an already-computed list — `method_scopes`/
  # `super_chain` (Kahn's algorithm over the class hierarchy) is real work,
  # and Elixir evaluates function arguments eagerly, so passing the
  # computed list would run it on every call regardless of whether
  # `fetch_providers` below even ends up needing it. Deferred like this, it
  # only actually runs on a cache miss.
  defp providers_for(key, selector, branch, scopes_fn) do
    AL.ResolutionCache.fetch_providers(branch, {key, selector}, fn ->
      for scope <- scopes_fn.(), id <- method_ids(scope, selector, branch), do: {scope, id}
    end)
  end

  # `{:instance, class}`, not the bare class atom — a shape's key (a map's
  # :class field, or the literal :list/:number for those shapes) can be the
  # exact same atom a class uses as *its own* receiver during its one-time
  # construction (:class's `new` calling allocate/init with self = the
  # class's name atom, for every class including :list and :number
  # themselves). Method_scopes computes those two cases differently (bare
  # atom: drops itself, scopes from its own class chain; instance: its own
  # super chain starting at itself) — sharing a cache key would let
  # whichever populates first silently answer for both.
  defp resolution_key(self) when is_list(self), do: {:instance, :list}
  defp resolution_key(self) when is_map(self), do: {:instance, Map.get(self, :class, :map)}
  defp resolution_key(self) when is_number(self), do: {:instance, :number}
  defp resolution_key(self), do: self

  def dnu(_self, :does_not_understand, _args, state), do: AL.backtrack(state)

  def dnu(self, method, args, state) do
    state =
      if default_dnu?(self, state.branch),
        do: record_dnu(state, self, method, args),
        else: state

    AL.interp(%Goal.Send{object: self, method: :does_not_understand, args: [method, args]}, state)
  end

  # True when receiver has no does_not_understand of its own — only then is
  # a miss worth reporting.
  defp default_dnu?(self, branch) do
    provider =
      Enum.find(AL.Dispatch.MethodOrder.method_scopes(self, branch), fn scope ->
        method_ids(scope, :does_not_understand, branch) != []
      end)

    provider in [:object, nil]
  end

  defp record_dnu(state, self, method, args) do
    suggestions = rank_suggestions(method, understood_method_names(self, state.branch))
    entry = {self, method, length(args), suggestions}
    %AL{state | diagnostics: [entry | state.diagnostics]}
  end

  # Rank known selectors by similarity to the missed one, for a "did you mean".
  defp rank_suggestions(selector, known) do
    target = to_string(selector)

    known
    |> Enum.reject(&(&1 == :does_not_understand))
    |> Enum.sort_by(&String.jaro_distance(target, to_string(&1)), :desc)
    |> Enum.take(3)
  end

  defp method_ids(obj, method, branch) do
    for {:method, _o, _n, id} <- AL.Object.scan_method(obj, method, :"$id", branch), do: id
  end

  defp has_matching_clause?(id, call_args, store, branch) do
    id in @primitive_methods or any_clause_matches?(id, call_args, store, branch)
  end

  defp any_clause_matches?(id, call_args, store, branch) do
    scope = Integer.to_string(AL.fresh_scope())

    Enum.any?(AL.cached_scan_clauses(id, branch), fn {:oapply, _id, _seq, head, _body} ->
      AL.Var.unify(AL.Var.freshen(head, scope), call_args, store, branch) != nil
    end)
  end
end
