# Dispatch legs → one domain-constraint mechanism

Full design history behind the summary in SKILL.md's "Known gaps." Read this
when actually working on dispatch candidate generation, `isa`/`in_domain`
unification, or the durable/generative leg split — skip it otherwise.

Mechanically done, semantically still in progress. Every leg answers the
same question — "self is unbound; what's its domain of possible values, and
how do we get a concrete one when forced (`labeling`, in CLP(FD) terms)?" —
differing only in how the domain is represented: a generative (`super:
:value`) class is a predicate domain ("unifies with one of class C's clause
heads, or with whatever its own `new`/`init` actually builds"), durable is
an explicit finite set (ids read from the log), and `in_domain/2`
(`AL.Var.ConstraintSet`'s `domain` field) is now a third, explicit-set
domain living directly on the var itself, no class involved at all — the
generalization this section used to describe as "not built" for isa. `isa`
stores a predicate domain (a class name, checked via `isa?/3`); `in_domain`
is the richer case that follows from it, an explicit value set rather than a
class-membership predicate.

- **Structural folded into the generative leg with no caveats** — `:list`'s
  cons/`[]` hypothesis *is* a generative case (a list's shape is its
  complete spec); the hardcoded special case predating `:value`'s existence
  is gone.
- **No `:ephemeral`/`:value` strategy split at all anymore — fully merged,
  not just sharing a mechanism.** `AL.Dispatch.generative_candidate/5`
  always calls the class's real `new` (`construct`/`allocate`/`init`), then
  reaches the method via `send_as_value` — there is no strategy argument, no
  second code path. Whether the resulting `self` stays open (ready for
  `send_as_value` to unify directly against the class's own clause heads,
  e.g. `:number`/`:letter_chain`) or comes back a real constructed map (e.g.
  `:interval`/`:mapset`) is entirely up to whether the class's own `:init`
  discards the constructed scaffold or keeps it — `:value`'s default
  `:init` (bootstrap.ex) is what makes the "stays open" case happen, not a
  VM-level branch. This replaced what used to be two parallel
  candidate-builders, two parallel descendant scans, and two
  `ResolutionCache` relations (now one `generative_descendants/1`, since
  `AL.Object`'s writers always invalidated both together anyway — they were
  never actually independent caches). A value class's `new`/`init` can
  still be overridden per-class with real logic (narrowing/rejecting during
  construction, not just at the end) if a concrete need shows up — not
  built, since no current value class needs it, but the mechanism doesn't
  block it.
- **Semantic collapse for classes with real construction logic is still
  open**: validation/defaults/invariants (e.g. a `union`'s left/right
  disjointness) need to be expressible as constraints, not imperative
  checks — this is exactly what `absento` (miniKanren's structural
  disequality: "X never appears anywhere inside Term", even as Term grows
  through still-open sub-parts — `dif`'s `migrate_constraints` re-attach
  trick, generalized to recurse into revealed structure) is for; not built.
  A generative candidate's construction already never touches anything
  durable or external (`AL.Interp.Store`'s goals no-op when `object` is a
  live map) — an invariant to keep honoring as classes gain real `init`
  logic, not something `absento` needs to newly establish.
- **Durable does not collapse into the others — a different resource, not a
  different amount of laziness.** Its domain is real, mutable, external,
  persistent state; producing a witness (`labeling`) means an actual scan,
  can race against concurrent writers, and is the one place backtracking
  away from a tried candidate doesn't undo anything (nothing durable was
  written by a `send`'s own candidate generation) — contrast a
  non-transactional effect like `send_elixir` reaching an external process,
  which *is* the one place nothing in AL rolls back, but that's a property
  of the goal type, not of durable dispatch specifically. This split is
  exactly why the durable leg was the one to get lazy first
  (`AL.Dispatch.force_durable_candidates/4`) — it was already the odd one
  out.
- End state: one dispatch loop asking each candidate class how it wants to
  describe its domain (an AL-level category/behaviour hook, not an Elixir
  special case per leg — consistent with "package means defpackage"), with
  durable staying the sole leg whose *labeling* is genuinely expensive and
  lazy, not because it's special-cased but because it's touching a
  different kind of resource than the other two. Sharper framing: durable
  vs. generative isn't two kinds of thing, it's one mechanism with two
  orthogonal strategies plugged in — an *allocation* strategy (how a new
  instance comes to exist: durable writes the log and mints an identity;
  generative constructs in-memory, possibly staying open) and a
  *domain-read* strategy (how existing candidates get enumerated: durable
  scans the log; generative tries the class's own clause heads, or, for
  `in_domain`, a fixed literal set). Once both axes are just parameters of
  the same mechanism rather than two dispatch legs, the double-proof
  conflict below isn't a special case to guard against, it's what happens
  when the same var's domain gets computed by two different strategies at
  once instead of one.
- **Concrete motivating case, found this session, now closed two ways**: a
  bare atom durably classified into a `super: :value` class whose own
  clause literally matches it (`vm_set_class(:two, :card_rank)` where
  `:card_rank` has `defmethod(:two, [:two])`) is reachable both as a
  durable object *and* as a generative candidate for the exact same fact —
  `findall` reports it twice, one proof per leg. Two guards now catch this,
  at two different points: `AL.Interp.Store`'s `SetClass` interp still
  rejects the combination at *classification* time (`vm_set_class`, via
  `AL.Dispatch.value_member?/3`), and `Goal.AssertValidClauseSelf` (native
  check, `AL.Interp.Store`, called only from `:defmethod`'s own accretion
  body in `bootstrap.ex`) rejects it even earlier, at *definition* time — a
  `super: :value` class can no longer define a clause with a bare atom as
  its self-pattern at all, so the ambiguous atom is never created in the
  first place. Neither is a general-purpose primitive; both are narrowly
  scoped to this one shape (bare atom self on a value class). The
  *principled* fix is still the unification above: if durable candidacy
  were expressed as a lazily-computed domain (same `ConstraintSet.domain`
  slot `in_domain/2` already uses, just computed from a durable scan
  instead of a fixed literal set), a var would have *one* domain, not two
  independent legs that can coincidentally agree on the same fact — the
  conflict dissolves structurally instead of needing a guard to catch it.
  `send`'s agnosticism about *which candidate kind will pan out* during
  search isn't the problem (that's ordinary backtracking, same as Prolog
  not knowing in advance which clause will match) — once something is
  concrete, durable or generative, it's never ambiguous; the guards exist
  for the narrower case of one *fact* being provable twice, not one
  *object* being unclear what it is. Explicitly deferred, not today's
  problem: a richer model where one Elixir datatype could belong to
  multiple possible classes — rejected as too complex and not performant
  enough to be worth it now.
- **A durable atom has exactly one direct class** — `AL.Interp.Store`'s
  `SetClass` interp also rejects reclassifying an atom that already carries
  a *different* direct class (`direct_classes/2`, via
  `AL.Object.scan_class/3`); `vm_retract_class` first if the reclassify is
  intentional. Supers/inheritance (`vm_set_super`) stay a free-form,
  unrestricted DAG — this only constrains an object's own class row, not
  its ancestry. Building this surfaced a real, previously-unresolved bug:
  `AL.Package`'s `defpackage` macro creates a durable receipt object via
  `new(:package, %{name: ...}, _)`, and `:object`'s default `:allocate`
  uses `args[:name]` as the durable identity — so a package whose main
  class shares its own name (a natural, common pattern) durably classifies
  the *same atom* as both `:package` (the receipt) and `:class` (the class
  declaration). Fixed by renaming the colliding class in each affected
  package (`elixir_process`, `interval`, `sudoku`, `mapset`, `equations`),
  not by changing `defpackage`'s own receipt mechanism — simpler for now,
  though it doesn't automatically prevent the same collision in a future
  package.
- **The durable and generative legs' requery step is now one shared
  helper**, not two hardcoded paths chosen up front by which leg you're in.
  `AL.Dispatch.requery_goals/4` splices an `Implies`/`IsVar` fragment that
  checks, *after* construction goals actually run, whether `self` is still
  open — open routes to `SendAsValue`, ground routes to `SendQuery`. This
  has to be a goal-level check, not an eager Elixir-level branch: for the
  generative leg, `new`/`Unify` haven't run yet at the point the requery
  goals are spliced in, so `self` always still looks like a var to an eager
  check regardless of which leg is running. For the durable leg
  (`force_durable_candidates`/`structural_candidate`), unification is
  eager, so by the time this runs `self` is already ground and the `IsVar`
  check is a no-op — same shared helper either way, no special casing. This
  replaced what used to be a hardcoded `SendAsValue` in one leg and a
  hardcoded `SendQuery` in the other. An earlier, more ambitious version of
  this unification effort (a new `vm_class_instances`/`Goal.ClassInstances`
  primitive, meant to make durable candidacy an overridable AL-level
  `:instances` method alongside generative's) was built, then fully
  reverted — it introduced a second primitive confusingly similar to
  `vm_class`, working against the goal of converging on fewer primitives,
  not more. `vm_class` stays the one lazy entry point it always was:
  register `isa` eagerly, defer the real scan until dispatch actually needs
  a witness.
