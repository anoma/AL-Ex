+
# AL internals

AL is an **object-oriented Prolog**: a WAM-style abstract machine (`AL.JAM`) over an **append-only
command log** in Mnesia. Live relational objects, bidirectional execution, ACID
transactions, durable + replayable state, Git-like branching.

## Mental model (design philosophy)

- **Commitment machine.** A stack of transactional state machines, ephemeral →
  durable. The durable base is the append-only on-disk command log (authoritative
  history); upper layers (the object projection) are *derived* from it, and a
  commit cascades upward. Everything runs in a Mnesia transaction so changes are
  atomic. Distribution comes from nodes *interacting*, not sharing a log — each
  node owns its history.
- **Objects are relational, not primary.** An object *emerges* from relations
  (`vm_class(a, …)`, `vm_super(…)`, `slot value …`); the object tables are a
  materialised view of the log — which is what makes replay, forks, and (planned)
  bitemporal queries fall out for free.
- **Inheritance is just a relation** (`vm_super`), so the class graph and its search
  order are ordinary data — multiple inheritance is free.
- **Backtracking is a feature.** WAM semantics give full backtracking +
  bidirectional execution: a var in receiver position turns a `send` into a query
  the runtime searches over.
- **Weigh what a design change forecloses, not just what it enables.** Every
  mechanism here sits at a real tradeoff point, not a strictly-better move — ask
  what capability is being traded away before adopting a change. Durability-by-
  default is AL's actual differentiator over Logtalk, but it's *why* generative
  construction has to exist as a separate, deliberately non-durable path —
  collapsing that distinction would silently foreclose either cheap
  backtracking-driven generation or durability-by-default, not both. Same
  reasoning applies to `super` vs. flat `import`: `super` is already a live,
  transitive form of import (dispatch re-derives it fresh every call) —
  "just import" would forecloses automatic propagation to classes/methods
  defined later.

## Architectural concerns

Five separable concerns, not a layered stack — several have no dependency on
each other at all, only on the command log itself:

- **Command log** (`AL.Command`, `lib/AL/command_log/command.ex`) — the
  append-only `{:command, t, tx_id, op}` Mnesia log. The one thing everything
  else either derives from or reacts to. Depends on nothing else here.
- **Views** (`AL.Object`, `AL.SourceStore`, `AL.Source` — `lib/AL/view/`) —
  materialised projections rebuilt by replaying the command log
  (`hydrate_since`/`hydrate_event`), plus `AL.Source`'s decompilation
  decompiler over that projection. Depend on the command log for what to
  project; nothing else depends on them *existing* — a view can always be
  rebuilt from the log alone.
- **Outbox** (`AL.Outbox`, `lib/AL/outbox.ex`) — receives a notification after
  a transaction commits, reads that transaction's `send_async`, `send_elixir`,
  and effect commands from the command log, and dispatches them outside the
  transaction. It is a parallel consumer of the log, independent of views and
  caches.
- **Caches** (`AL.ResolutionCache`, `lib/AL/cache/resolution_cache.ex`) —
  derived, disposable, per-branch memoization of expensive queries *over*
  views (`providers/3`, `oapply_clauses`, `native`, …), invalidated by the
  same writes that mutate the view they cache. Never a source of truth —
  correctness never depends on a cache entry existing, only speed does.
- **Extensible VM** (`AL.Native`, `AL.Native.Registry` — `lib/AL/native/`
  — and someday a jets mechanism) — the seam where the machine's
  dispatch can be handed capability the kernel has no way to derive itself.
  A view holds only a *symbolic reference* to what's expected (a durable
  `:native` fact — module/function/arity/style, a name, not code);
  *supplying* the implementation is this concern's own job, done via
  ordinary Elixir/OTP deployment (config, releases), never via anything the
  command log itself can execute. See [[al-natives-vs-jets-kernel-runtime]]
  for why a future jet, unlike a native, wouldn't need even the symbolic
  reference to be durable.

The engine proper (`AL` itself, `AL.JAM`, `AL.Dispatch`, `AL.Var`,
`AL.Choicepoint`) isn't a sixth concern of its own — it's what executes goals
*against* these five: reading views and caches, writing back only through
the command log's own `AL.Command`/`AL.Object` entry points (never touching
Mnesia directly outside `lib/AL/command_log/`, `lib/AL/view/`, and
`lib/AL/branch.ex`), and reaching into the extensible VM specifically at
`OApply` dispatch. `AL.Branch` (`lib/AL/branch.ex`) sits alongside all five
rather than inside any one of them — forking genuinely spans Command Log and
Views (copies a log prefix *and* provisions the projection/cache tables) and
also starts/stops the Outbox per branch.

## Architecture (lib/AL)

- **`AL` (lib/AL.ex)** — the transaction driver:
  - `AL.run(text, bindings: %{"Name" => value})` → `AL.Syntax` parses the AL
    source to `AL.Goal` structs → `eval_with_retained_source` runs them in
    `:mnesia.transaction`. `branch: b` targets fork `b`; otherwise `run`
    uses `AL.Branch.head()`.
  - State = `%AL{active_choicepoint, choicepoint_stack, branch, tx_id, trace, …}`.
    `start_program/1` compiles the whole program into one machine query
    (`AL.JAM.query/1`, an internal progress marker after each top-level goal), so the
    active choicepoint's goals only ever hold `{:resume, frame}` entries, and
    frozen goals are parked as `{frame_id, code, slots}` in both the driver and
    the machine. `continue/1` resumes the machine,
    `apply_machine_result/2` turns what it yields back into driver state
    (installed choices, mutations, diagnostics, collection and `forall`
    continuations, cuts and commits), and `backtrack/1` pops the stack. Success →
    `{:atomic, {output_vars, state}}`; failure `:mnesia.abort`s → `{:aborted, reason}`.
  - There is no goal interpreter. Every goal runs as machine code (see `AL.JAM`).
  - Object creation is **three-phase**: `construct` (ephemeral object, e.g.
    `%{class: self}`) → `allocate` (persist / give identity) → `init` (setup).
    `new` on `:class` chains all three (AL's take on ObjVLisp allocate/initialize).
- **`AL.JAM` (lib/AL/jam.ex, lib/AL/jam/)** — the abstract machine that executes
  every goal. `AL.JAM.Compiler` compiles a method's clauses (head matchers from
  `AL.JAM.Head`, register-addressed instructions over `AL.JAM.Operand`s, clause
  indexing via `AL.ClauseIndex`) and caches them per branch. `AL.ClauseIndex`
  shares up to three literal decisions across clauses when multiple head
  positions discriminate, then returns source-ordered clause records for their
  own head actions; list-shape methods retain the existing flat index. The
  compiler also compiles runtime goal lists (`runtime/1`) for queries, relation rewrites and woken
  goals. Direct method invocations pass through `AL.JAM.IR`: an `:invoke`
  semantic operation is rewritten by `AL.JAM.IR.Kernel` where applicable,
  then its operands are encoded for JAM. `AL.JAM.Registers` tracks fresh
  register facts during specialization; a `forall` is a barrier for earlier
  instructions, while unused locals after the last `forall` can still be
  specialized. `AL.JAM.step/12` runs instructions; a frame is
  `{id, code, pc, slots, returns, store, pending}` and alternatives live in the
  machine's own choice list. A direct `AL.Goal.OApply` compiles to `:call_method`.
  Direct methods and sends share clause selection, IR rejection decisions,
  specialized head matching, and call entry. Direct calls resolve a bound
  method identity without inheritance lookup and accept arbitrary receivers;
  their argument operands feed the matcher directly when available. Resolved
  direct targets (compiled methods, natives, or primitives) are cached by
  method identity in the execution-local target map, discarded at the same
  driver boundaries as send targets. The separate head-instruction compiler,
  machine-head wrappers, lazy retry frames, and interpreter cases were removed.
  Tracing uses the same matcher with the existing complete clause trace path.
  `test/jam_direct_method_test.exs` covers arbitrary receivers, structured
  aliases, dynamic argument lists, mutation invalidation, and cut scopes.
  Instruction families delegate to
  `AL.JAM.Relation` (relational reads: class, super, method, clause, slot,
  command, branch facts, scheduling), `AL.JAM.Mutation` (durable writes and
  driver-state effects: output and source scopes), `AL.JAM.Primitive`
  (term primitives), `AL.JAM.Constraint` (domains, `all_dif`, `floor_divide`,
  `either`), `AL.JAM.Label` (labelling), `AL.JAM.Format` (`vm_format`) and
  `AL.JAM.Trace` (ports). A goal the compiler cannot express is a compile
  error, never a handoff. The machine yields to the driver only for effects
  that need transaction state (`:mutation`), collection or `forall` results
  that need the driver, cuts and commits that reach driver choicepoints,
  diagnostics, failure, and a spent step budget (`:suspend`, resumed as-is).
- **`AL.JAM.IR.Binding`** — shared compile-time freshness, escape, and safe
  equality propagation rules for inference, dataflow, and region planning.
  Arithmetic is evaluated only when ground; unresolved arithmetic remains a
  runtime constraint. Register specialization tracks slot indices after
  lowering and keeps its separate instruction-level facts.
- **`AL.JAM.IR.Loop`** — automatic fusion for a proven two-clause list
  recurrence. It lowers clause bodies through the semantic IR, inlines bound
  pure sends, and proves that each recursive step consumes one list cell,
  optionally checks its integer element, and copies it to an output with an
  invariant tail. The driver can be the receiver itself; unguarded copying
  preserves arbitrary terms and variable aliases. Disjoint integer guard
  intervals establish determinism; restrictions
  on other arguments, overlapping alternatives, effects, cuts and unsupported
  operations reject the plan. No selector or grammar name is recognized.
  The result is a compiled BEAM traversal closure with specialized guard
  closures, reusable across element values and list lengths. It does not
  dynamically create modules or evaluate quoted functions in the hot loop.
  Normal untraced bound sends attempt fusion with an unconstrained output,
  no pending suspensions, and sufficient step budget. Failed guards, unknown
  list elements/tails and unsupported modes fall back to ordinary JAM.
  Branch-local `compiled_plans` cache entries validate dispatch identities
  and exact source clauses before entering the transaction-local dispatch
  cache. Existing dispatch invalidation also clears these local plans after
  method, native, provider and hierarchy mutations; persistent stale plans
  are validated and replaced on use.
  The 1,000-element generation workload measured about 20x fewer reductions
  and two store entries instead of 3,002. This is a list-recurrence result,
  not a claim about whole-parser performance or arbitrary recursive code.
- **`AL.JAM.IR.Search`** — recognizes a two-clause list-head search through
  semantic IR: one clause matches an element, the other sends the unchanged
  arguments to the tail. It skips definitely unequal scalar heads before
  ordinary clause selection, charging the step budget without constructing
  intermediate call frames or bindings. Potential matches, unknown or
  structural values, and the last cell retain ordinary execution, preserving
  duplicate answers, open modes, and missing-method behavior. Recognition is
  cached with transaction-local dispatch and invalidated by the same writes.
  Traced execution and pending suspensions bypass pruning. The recognition
  depends on clause structure, not a particular selector name.
- **Language benchmarks** — `bench/parse_file.exs` parses a checked-in AL
  class/method source with both the native reader and the AL grammar, checking
  equivalent ASTs. `bench/bnf.exs` generates the complete BNF and verifies it
  against `lib/AL/syntax.bnf`. Both use isolated stores, warmed timings and
  BEAM reductions; run with `mix run --no-start`. Runtime startup and file
  reads are excluded. `bench/README.md` describes inputs and controls.
- **`AL.JAM.IR.Plan`** — bounded query planning at bound send sites. The
  caller's encoded operands supply literal and bounded structural facts;
  unknown fields remain parameters. The planner propagates those facts
  through semantic IR, folds atom/class filters and known functor projections,
  and inlines callee heads only when subsumption proves they match. It can
  bind local temporaries that have not escaped into the root head, eliminating
  finite argument-list construction before a send. Caller-visible variables
  remain protected. Supported AST goals lower once into semantic IR, which
  the compiler emits directly. Fresh local equality propagates aliases and
  shapes into later operations. Retained operations mark referenced variables
  escaped and stop metadata-dependent inlining; local propagation resumes in
  the continuation. A folded failure retains all preceding runtime operations.
  Ordinary send inlining keeps methods containing cuts, next-method calls,
  or `forall` at their own boundary (`forall` depends on the callee's
  head-variable sharing scope). A separate provider-prefix transformation
  resolves leading `next` chains at a bound root send. Each provider must
  have one clause with distinct variable head arguments; its continuation
  must be context-free. The transformation alpha-renames provider locals,
  forwards the explicit receiver and arguments, and concatenates IR graphs.
  It retains alternatives inside provider bodies and refuses cuts, multiple
  or patterned provider clauses, native providers, and effects before `next`.
  Plans guard the complete provider cursor and each provider's source rows,
  alongside root dispatch and branch identity. No new JAM instruction is
  needed. Clause and
  answer order are preserved. Failed branches keep a failing root clause when
  necessary to distinguish body failure from missing-method dispatch.
  Planning has a 48-call expansion budget and a 24-path limit. Automatic
  selection also rejects plans that increase the source clause count. If region
  expansion is rejected, the planner retries the bounded prefix rather than
  discarding its safe inlining. Plans
  record their input facts, inlining count, method sources, and class-read
  dependencies. `AL.ResolutionCache.fetch_plan/4` validates persistent plans
  before transaction-local reuse. The existing send-target cache retains the
  selected compiled plan with an exact receiver guard when specialized;
  traced execution and pending suspensions use the ordinary target.
  `test/jam_plan_test.exs` covers argument construction collapsing to one
  equality, dependency edits, class guards, effects, cuts, duplicate answers,
  missing-method behavior, distinct receiver values sharing a class, local
  equality propagation, opaque continuations, suspension and caller aliases.
  The 172-byte `bench/fixtures/point.al` parser workload measured 12.546 ms
  median and 1,631,675 reductions after provider fusion (11 samples, one
  scheduler), versus 14.313 ms and 1,727,678 before. Temporary in-memory
  dispatch instrumentation, run separately from timing with three identical
  warm samples, showed `next` calls falling from 1,010 to 190 and clause
  matches from 4,204 to 3,384. Sends remained 1,561. Of 1,035 dispatch
  alternatives created, 860 were resumed and 175 were unvisited when parsing
  returned, unchanged by fusion. Snapshot matching reported no collisions;
  these are visited alternatives, not successful answers. Unvisited does not
  establish deadness or determinism. The largest unvisited groups were
  `zero_or_more` (76) and inherited `symbol` (46). All 270 `match_pattern`
  alternatives were resumed. Future determinism work should distinguish
  avoidable failing search from alternatives merely left over at first answer.
- **`AL.JAM.IR.Rejection`** — extracts necessary input conditions from the
  first IR operation of each clause: `atom`, `var`, `functor`, or a constant
  structural `class` test on a head argument. These summaries reject only
  provably incompatible bound arguments before head matching, local-variable
  allocation, and choicepoint construction. They never execute body goals or
  read mutable class metadata. Open variables, durable atom classes, unknown
  map classes, and unsupported structures retain normal execution. No test is
  moved across a preceding effect, cut, binding, or call. Methods without a
  head index whose tests share an argument position get precomputed ordered
  clause buckets, selected by one runtime shape classification; other methods
  use conservative filtering after the existing head index. Single-clause
  methods keep the ordinary path. If no retained clause head matches, one
  original matching clause is entered to fail normally, preserving the
  distinction between body failure and missing-method dispatch. Traced calls
  retain complete original clause execution. Method recompilation rebuilds
  rejection summaries through the existing cache invalidation path.
  `test/jam_rejection_test.exs` covers shape selection, aliases, open modes,
  mutable classes, effects, cuts, failed bodies, method edits, and duplicates.
  `bench/parse_search_profile.exs` reproducibly counts ordinary send and `next`
  alternatives with temporary process-local instrumentation; it is separate
  from the timing benchmark. On the 172-byte fixture, three identical warm
  samples showed created alternatives falling from 1,035 to 597, resumed
  alternatives from 860 to 460, and first-instruction failures of resumed
  alternatives from 290 to 35. The remaining 35 are unifications (34 in
  `blanks`, one in `optional`). Clause matches fell from 3,384 to 2,946 in
  temporary dispatch instrumentation. An uncontended 11-sample, one-scheduler
  comparison measured 1,644,843 to 1,587,791 reductions (3.5% fewer), but
  median time was essentially flat, 12.331 to 12.378 ms. This is reduced
  search and allocation, not evidence of a wall-clock speedup.
- **`AL.JAM.IR.MethodIdentity`** — guarded reuse of the current method
  identity inside direct method bodies. It recognizes a head argument used as
  a dynamic invocation target and forwarded at the same position. When every
  clause has an unrestricted, unrepeated variable at that position, it prepares
  an internal variant that substitutes the known method ID in the body and
  ignores that already-validated head field. The public call retains every
  argument and its original arity. Entry selects this variant only when the
  supplied argument dereferences to the called method ID; open or different
  values use the original method. Compiled recursive calls carry a
  `method_identity` operand annotation recording the proven position, so they
  can reuse the variant without repeating the argument guard. Method lookup
  still observes edits through the ordinary target-cache lifetime; if a newly
  compiled method lacks a variant at that position, the call uses its original
  body with the unchanged argument list. Traces retain original bodies, and
  operand reconstruction exposes the ordinary method ID. No source rewrite,
  new public goal, or calling-convention change is involved. The successor
  benchmark still passes `[N, Target, Id]`; direct-call reductions at 10,000
  steps measured about 2.50M versus 2.57M before this specialization, with
  send at 2.65M. Timing was noisy. Tests cover different and open targets,
  retained arity, observable argument values, alternatives, and edits during
  recursive execution.
- **`AL.JAM.IR.Program`** — the executable compiler boundary for ordinary
  methods, callables and runtime queries. Bodies are block graphs, with explicit
  jumps, call continuations, ordered choices and shared joins, committed
  conditionals, failure, method returns and condition-local yields. Blocks
  expose conservative failure/backtracking and suspension behavior. Scoped
  operations own nested programs. `IR.Lower` recognizes AST operations;
  `IR.Emit` selects existing JAM instructions after graph transformations.
  Compiler register allocation reads IR variables, and branch-scoped method IR
  is cached by `Compiler.fetch_ir/2`. The planner consumes those programs,
  substitutes values, and splices callee graphs into continuations; it does
  not reopen AST bodies or flatten graphs into goal lists. It conservatively
  specializes shared continuations of ordered choices using joined facts.
  Committed conditionals retain their existing dispatch boundary. Source rows
  remain cache dependencies.
  `forall` capture metadata is derived from the nested programs' variable sets;
  runtime execution no longer scans its AST. AST-valued operands still exist
  as language data (dynamic callable bodies, definitions and source retention).
  The current emitter accepts the structured acyclic graphs produced by
  lowering and inlining; recursive sends remain calls.
- **`AL.JAM.Callable` / `Compiler.fetch_callable`** — compile the callable's
  unsubstituted head/body template with canonical capture slots. Templates
  reserve capture registers before other locals; their head matchers treat
  captures as initialized registers. Invocation resolves/freshens the capture
  environment in one substitution traversal, writes those registers directly,
  then matches only the argument head. It does not match an extra environment
  list. Freshening preserves aliases and per-invocation local-variable semantics.
  `IR.Closure` identifies statically executable bodies; `IR.Emit` embeds their
  template and capture operands in the existing call instruction's body operand.
  Invoking those sites requires no source decoding, variable renaming or compiler
  lookup. The source operand is retained for tracing and pending-goal recovery;
  compiled metadata never enters the language value or durable source.
  Genuinely dynamic bodies use the transaction template cache. Runtime-supplied
  goal nodes/selectors are materialized before that fallback compiles them.
  Changing ordinary capture values never invalidates a static template.
- **`AL.JAM.IR.Region`** — a selection of blocks in an IR program, with an
  entry, outgoing graph edges and conservative input/output variable sets.
  Regions no longer wrap lists that the compiler flattens before compiling.
  Interfaces come from backward liveness, using fresh definitions and the
  caller-supplied method head variables as observable inputs/outputs. Region
  exits use execution edges rather than synthetic branch-join references.
  Selected regions also expose conservative determinism and suspension
  contracts. Compilation combines straight-line blocks with one incoming
  edge and optimizes their bindings together before emitting existing JAM
  instructions. An eligibility scan avoids analysis of bodies without local
  binding candidates; branched bodies still receive join analysis. This is
  algebraic region compilation, not a native executor for surviving operations.
  Loop-region emission remains future work.
- **`AL.JAM.IR.Selection`** — runs after semantic region analysis and before
  operand emission/register specialization. It composes adjacent comparisons
  of the same operand against numeric literals into a selected `numeric_tests`
  operation, keeping the original semantic operations as its fallback. This
  is an IR-to-machine selection pass; it does not recognize AST goals or AL
  library predicates. Control-flow boundaries and intervening operations stop
  composition. The JAM instruction shallow-reads its operand once and performs
  ordered numeric tests without entering the generic constraint engine.
  Non-numeric/open values, tracing, pending wakeups and insufficient budgets
  execute the original instruction sequence. Success and failure retain the
  original step accounting; failure identifies the original comparison and
  pending-goal reconstruction expands the selected operation. Root query
  progress markers are not fused.
- **`AL.JAM.IR.Inference`** — classifies operand modes as ground, fresh or
  unknown, and operations as det, semidet or unknown with suspension/effect
  information. A fresh acyclic binding can establish a symbolic value;
  ground arithmetic uses the runtime evaluator before establishing a fact.
  Unresolved arithmetic, caller-visible unification and opaque calls retain
  conservative contracts. These proofs drive dataflow substitution/removal;
  region contracts aggregate the same information.
- **`AL.JAM.IR.Dataflow`** — forward symbolic-value facts and escape information
  over structured branch graphs, followed by backward fixed-point liveness.
  Only fresh, unescaped variable bindings establish exact values; head
  variables remain observable. Joins retain values identical on every live
  incoming path, including exact numeric representation. Conditional failure
  starts the otherwise branch from the precondition bindings. Effects seen on
  failed alternatives still invalidate metadata assumptions and escape facts.
  The pass substitutes known values and removes only dead, fresh bindings
  that inference proves cannot fail or wake constraints. Ordered alternatives are
  retained even when both arms become empty, preserving duplicate answers.
  Eligible method regions and the region planner use the pass. Liveness is
  conservative for opaque calls and scopes; it does not assume determinism or
  turn logical unification into arbitrary register overwrites.
  `test/jam_ir_program_test.exs` covers shared joins and ordered duplicate
  answers, direct compilation of rewritten IR, conditional return isolation
  during graph splicing, region exits and nested scoped programs.
- **`AL.Syntax` (lib/AL/syntax.ex)** — the only AL reader: a pure lexer,
  precedence parser from AL source to compound terms (`AL.Goal.Compound`),
  plus exact definition ranges for source retention. No machine state.
  `lib/AL/syntax.bnf` is generated by `mix al.bnf` from the `al_grammar` DCG in
  bootstrap, so it describes that grammar, which does not yet cover everything
  the reader accepts. The
  reader groups a source's `owner >> sel` clauses and emits `clear_method`
  before each group's first clause, so a source defines each method it
  mentions (Prolog reconsult); `clear_method` (bootstrap) retracts the
  method's clauses and keeps its id. The printer hides a `clear_method` that
  opens a group, so printing and reading stay exact inverses.
  `AL.Syntax.Printer` is its inverse (goals → AL source), used by every
  decompiled view.
- **`AL.Dispatch` (lib/AL/dispatch/dispatch.ex)** — the machine's dispatch
  queries: `target/3` (a ground receiver's first provider, or a native,
  or the understood selectors when the selector is unbound),
  `open_targets/4` (one plan per provider for an unbound receiver: a
  class provider constrains the receiver with `isa` and a selected-provider
  entry, a singleton provider binds it, a native provider applies directly),
  `next_provider/2` (the next provider from a `call_next_method` cursor),
  `miss_fails?/3` (whether a miss reports a diagnostic or sends
  `does_not_understand`), plus provider resolution, ivar specs and class
  membership (`isa_conflict?/3`, `value_member?/3`).
- **`AL.Dispatch.MethodOrder` (lib/AL/dispatch/method_order.ex)** — the
  resolution-order topological sort (`method_scopes/2`, `super_chain/3`, Kahn's
  algorithm). Pure functions of a receiver/class and a branch, no choicepoint or
  bindings involved — the most standalone piece of the whole dispatch subsystem.
- **`AL.ResolutionCache` (lib/AL/cache/resolution_cache.ex)** — per-branch,
  flush-on-write Mnesia `ram_copies` (not ETS — a table has to outlive whichever
  transient process forked the branch) memoizing `providers/3`,
  `generative_descendants/1`, `durable_classes/1`, `answers_selector?` — pure
  functions of durable state, re-derived otherwise on every open dispatch.
  Naming follows `AL.Command`/`AL.Object`'s per-branch convention
  (`al_providers_cache@f`, …); created/dropped alongside a branch's other
  tables in `AL.Branch.setup/create_fork/discard`.
- **`AL.Choicepoint` (lib/AL/choicepoint.ex)** — the driver's choicepoint
  struct; pure data.
- **`AL.Var` (lib/AL/var/var.ex)** — unification against one unified **store**: a
  var→entry map where an entry is either a bare bound term or an
  `AL.Var.ConstraintSet{dif, isa, bounds, domain}` struct for a still-open var
  carrying constraints — a binding is just the maximally-specific case of
  "what's known about this var," not a different kind of fact, and standard CLP
  theory doesn't distinguish them either. The struct (not a plain map) is what
  lets `deref/2` tell "still open, here's what's known" apart from "bound to a
  term that happens to be a plain map." `deref`, `subst`, `freshen`, `unify` all
  take this one store. `bind/4` runs an **occurs-check** (cons-aware for
  improper lists `[h | $tail]`) and checks the constraint set on a var *before*
  overwriting it with a bind (capture-then-check) — the one choke point a
  constraint is guaranteed to see every bind through, dispatch's own candidate
  generation included. `dif/2` and `isa` (`add_isa/3`) are its two original
  tenants, `bounds`/`domain` (see "Known gaps") joined later, all through the
  same slot. `isa_of/2` is the read side. Verifying `isa` needs a `branch` —
  `:number`/`:list`/`:map` are decidable from the term's own shape; a value
  class beyond those three is provable by matching one of its own
  *discriminating* clause heads (`AL.Dispatch.value_member?/3`); every other
  class is a relational fact costing one class-chain lookup. `AL.unify/3` (in
  `AL.ex`) is the state-aware convenience every other module calls;
  `AL.Var.unify/4` directly only when there's no `AL` state to pull
  `store`/`branch` from. Variables are `{:"$var", "x"}` with binary names; fresh variables wrap
  them as `{:"$fresh", base, scope}`. Returned binding and constraint maps
  use binary keys such as `"$X"`. Mnesia match-spec placeholders remain
  Erlang atoms at the query boundary; they are not stored AL variables.
- **`AL.Command` (lib/AL/command_log/command.ex)** — the event log. Each mutating
  goal writes a `{:command, t, tx_id, op}` row. `t` is a **global monotonic
  counter** shared across stores, so commands are globally ordered.
- **`AL.Object` (lib/AL/view/object.ex)** — the projection: a RAM
  materialisation of the log (class/super/method/oapply as `:bag`, slots as
  `:set`). Rebuilt by replay (`hydrate_since`); `scan_*` query it.
- **`AL.Branch` (lib/AL/branch.ex)** — forks. `fork(at \\ :tip, from \\
  head())` copies `from`'s log prefix into a new store + projection; writes
  diverge. Forks nest. `checkout` sets HEAD; `discard` tears a fork down.
  `AL.Command`/`AL.Object`/`AL.Branch` *are* the append-only substrate
  (`lib/AL/command_log/`, `lib/AL/view/`, `lib/AL/branch.ex` respectively) —
  nothing else in the engine reaches into Mnesia directly.
- **`AL.TransactionProgram` (lib/AL/transaction_program.ex)** — loads
  `priv/programs/<name>.al` (first form `defprogram name #{version => V,
  deps => [...]}.`), executes it, and creates a durable execution receipt;
  dependency-ordered, reversible `uninstall`. `bootstrap` is foundational
  (class/object/method machinery **and** the list protocol).
- **Package protocol (`priv/programs/package_system.al`)** —
  `:package` is the metaclass of package classes and `:package_build` supplies
  their instances' common build protocol. Package metadata and builds are
  durable branch state. `AL.Package.import/2` validates and atomically imports a
  portable manifest plus AL definition documents into an explicit branch;
  export and live package projection are not implemented yet.
- **`AL.Outbox` (lib/AL/outbox.ex)** — async. `send_async`/`send_elixir` and
  effects only write commands inside the transaction; after commit the outbox
  dispatches those commands. **One outbox per branch** runs under a
  DynamicSupervisor, so fork async stays on the fork. `Branch.fork`/`discard`
  start/stop it.
- **`AL.Trace`/`AL.Trace.Domino` (lib/AL/trace/)** — introspection. See "The
  tracing model" below for retained trace families, Domino call-tree evidence,
  and `AL.Trace`'s live tracepoint printer.
- **`AL.Source` (lib/AL/view/source.ex)** — decompiles a stored goal pattern
  back into readable AL surface syntax; a Views concern, not engine
  introspection, since it reads back out of the projection rather than
  tracing live execution. Used by the GlamorousToolkit method-coder view in
  `AL.GtBridge` (`lib/AL/gt_bridge.ex`, renamed from the unrelated
  `AL.Views`).

## Execution model: choicepoints, marks, cut

The machine keeps its own choice list of frames plus **boundary markers**:

- `{:jam_cut, ref}` — pushed below a call's alternatives when its clauses
  contain a cut (`:cut_scope`); the frame id carries the same ref, so `cut`
  drops the choice list to that marker. A cut in a `freeze` body opens its own
  scope, so it is local to the frozen goal.
- `:implies_mark` — pushed by `->`; the condition's `{:commit, then}` drops the
  choices down to and including it. `or` pushes the right branch as a plain
  alternative.
- `{:trace_alternative, scope, seq, entry}` and `{:trace_fail, tag, scope}` —
  only while tracing, so retries report `clause_chosen` and Fail ports.

When the machine yields, the driver installs the remaining choices as its own
choicepoints: frames become `%Choicepoint{goals: [{:resume, frame}]}`,
`{:jam_cut, _}` and `:implies_mark` stay as marks, and trace markers become
`{:mark, scope}`/`{:method_mark, scope}`. A cut whose marker is already on the
driver stack returns `{:cut, …}` and the driver drops its stack to it.

## How a `send` evaluates

A `send` compiles to a `{:send, site, object, method, args}` instruction (or
`{:send_local, …}` when its outputs are fresh locals the callee can write
directly). At runtime:

1. **Unbound receiver** → `AL.Dispatch.open_targets/4` builds one plan
   per provider of the selector, tried in order as alternatives.
2. **Unbound selector** → the receiver's understood selectors, one alternative
   per name, each re-sent as a query (a miss fails quietly).
3. **Both ground** → `target/3` picks the first provider (cached per
   receiver key and selector in the frame's targets), the callee's compiled
   clauses are selected by index and head match, and every matching clause is
   an alternative in `seq` order. A provider cursor rides in the frame for
   `call_next_method`.
4. **No provider** → a diagnostic when the receiver has the default
   `does_not_understand`, otherwise a re-send of `does_not_understand`.
   No matching clause → the same choice. A query send (`{:query, ref}` site)
   just fails.

`_` in the receiver or selector position finds no provider. The reader turns
each written `_` into its own fresh variable (`$_@N`), so `:"$_"` only appears
in Elixir-built patterns.

## Tables

Fields key-first. Projection tables (`AL.Object`) are per-branch `ram_copies`, a
**materialised view** rebuilt by replaying `command` in `t`-order; the log +
lineage are the durable truth.

Projection (`AL.Object`):
- `class {object, class}` · `:bag` — `object` is an instance of `class` (several
  rows = multiple classification).
- `super {object, super}` · `:bag` — class `object` has superclass `super`
  (several rows = multiple inheritance).
- `slots {object, slots}` · `:set` — `object`'s slot map; one row, latest wins.
- `method {object, method_name, method_id}` · `:bag` — class/object answers
  `method_name` with method object `method_id`; resolved up the class/super chain.
- `oapply {object, seq, head, body}` · `:bag` — the **clauses** of a method:
  `object` is a `method_id`, `head` the arg pattern (`[self | …]`), `body` the goal
  list. `seq` is an explicit non-neg integer ordering key — `scan_oapply` sorts by
  it, so clause try-order is first-class data, stable across replay/fork.

Log + metadata (`AL.Command`, durable):
- `command {t, tx_id, command}` · `:ordered_set` — the append-only log. `t` is the
  global monotonic ordering key; `command` is the op. Authoritative; all else
  derives from it.
- `meta {key, value}` · `:set` — per-branch key/value (e.g. `:head` → current
  branch, kept in `:main`'s `meta`).

Lineage (`AL.Branch`, `:main` only):
- `branch {parent, child}` · `:bag` — fork lineage edges; HEAD is `meta[:head]`.

`:main` uses base table names; fork `f` uses `@f`-suffixed tables (`class@f`, …)
created with `record_name:` the base relation, so record tags and scan patterns
are identical across stores. Almost every `AL.Object`/`AL.Command` function
takes a trailing `branch \\ :main`.

## The tracing model (`AL.Trace`, `lib/AL/trace/`)

Retained tracing is controlled by the composable `trace:` flag set and stored
under `state.trace`. No flags is the default and retains no execution history.
`:domino` records the structured call tree plus constraint evidence, and `:vm`
interleaves every VM goal. Constraint events are classified entries, not a
separate producer or flag. A future query explainer can add a new producer
without another top-level state field. Domino traces record 4 ports
— Call/Exit/Redo/Fail — at 2 levels, **method** (dispatch picking a provider, can itself
backtrack over candidate classes) wrapping **clause** (which clause of the
chosen method runs). Same Byrd-box framing classic Prolog tracers use, doubled
because AL has dispatch on top of clause selection where Prolog only has the
latter. Call/Exit carry a map of every variable still open at that moment,
including variables nested inside a receiver or argument, resolved against
*that scope's own* store, not the run's final one — a var can be merely narrowed
by one call and only pinned down later by something unrelated, so the final
store would misattribute it; Redo/Fail stay bare. Constraint events likewise
retain their immediate input and output descriptions. A collection answer owns
the final solution description; it is never substituted into its earlier
constraint nodes.
The machine emits every port through `AL.JAM.Trace` (the SWI-Prolog
approach: one engine with port hooks, and call-hiding shortcuts such as
`send_local` turned off while tracing). A traced send opens a method box
(`method_call/6`) and its callee a clause box (`clause_call/5`); a
`{:trace_exit, scope}` entry under the callee's return address fires Exit when
the callee returns and propagates it to the enclosing method box. Traced frame
ids carry their scope and clause number, `{:traced, scope, seq, id}`, so a
retry can report Redo and `clause_chosen`. `state.trace.runtime.scopes` (one map,
keyed by scope: `%{parent, kind, open_vars, exited}`) is the bookkeeping — set
at Call, read at Exit/Redo/Fail, deleted at Fail. During a machine run the
trace lives in the process dictionary and is handed back to the driver state
on every yield.

Every retained entry is an `%AL.Trace.Event{kind, payload}` tagged as either
`:domino` or `:vm`. Raw goals plus `:backtrack`/`:flounder` join
`state.trace.events` when a run enables `:vm` — interleaved in chronological
order, so a raw goal sits right next to the Call that's its context, no
cross-referencing needed. `state.trace.runtime` holds ephemeral scope,
tracepoint, and live-printer state; the trace's custom inspector omits it.
`AL.Trace.derivation_tree/1` accepts the completed `%AL{}` state, reads both
the retained journal and final variable store itself, and restores execution
order internally before constructing the successful derivation. Its materialized
tree alternates call nodes with successful answer nodes: a call owns its answers;
each answer owns its clause, derived bindings, and ordered nested method or
constraint steps. A method answer's derivation spans that method Call/Exit,
while a constraint node's derivation spans only that constraint's execution.
Redo rewinds later siblings and invalidates ancestor answers, so unsuccessful
attempts do not leak into the surviving tree.
`AL.Trace.render/1` prints a chronological event journal and reconstructs depth
by walking Call/Exit as it goes. `AL.Trace.render_tree/1` prints the successful
call/answer tree returned by `derivation_tree/1`. The event renderer uses the same
formatters the live `AL.trace(:selector)` printer uses (`AL.Trace.call/5`,
`exit/4`, `redo/4`, `fail/4` — all `(level, depth, receiver, method[, args])`,
`level` is `:method` or `:clause`). `iex -S mix debug` sets
`IEx.configure(inspect: [limit: :infinity, charlists: :as_lists])` for
reading a long trace by hand — invoking a custom Mix task this way skips the
normal app-start Mix does for you, so the task itself calls
`Mix.Task.run("app.start")` first (`lib/mix/tasks/debug.ex`). Examples in
`e_AL_trace.ex`.

`findall`, `forall`, and `not` run their conditions as isolated child searches
with a fresh trace (root scope 0), so bindings and choicepoints cannot leak. Their
finalized retained events
are prepended back into the outer reverse-chronological event stream, so tracing
still shows the work performed inside those meta-goals. Domino collection
markers retain each successful inner solution store before exhaustive search
resumes. `derivation_tree/1` merges those successful paths by their retained
call and answer identities. The collector is one call-like node with one answer;
the calls inside its condition own the actual alternatives. This keeps common
prefix constraints once and places downstream enumeration beneath the answer
whose constraints it consumes.

`AL.Trace.dispatch/3` (live-printer only, fired for an unbound receiver when
the selector is a tracepoint) prints the providers an open send will try, before
any of them run. Example: `trace_shows_dispatch_legs` in `e_AL_trace.ex`.

`call_next_method` opens a clause box for the next provider under the current
scope; it opens no method box of its own.

## Debugging a live session's failure state

A failed `run`/`next_solution` doesn't just hand back a curated summary — the
reason map (`message`/`reason`/`failed_on`/`trace`) also carries **`state`**:
the actual final `%AL{}`, whatever store/choicepoint_stack the last attempt
left behind before the stack exhausted. `reason.state` lets you inspect *what
was true when the last goal failed* — e.g.
`AL.Var.isa_of(reason.state.active_choicepoint.store, var)` for what was still
parked on a var, not just that some goal failed. Stripped back out (`nil`) on
the `heap:`-capped `eval` path (`AL.shed/1`), which exists specifically to
bound what crosses the process boundary. Example:
`failed_run_exposes_the_final_state` in `e_AL_failures.ex`.

A `a = b` failing because a `dif`/`isa` constraint rejected it looks
identical to an ordinary structural mismatch — when a machine run fails on an
`=` instruction, the driver calls `AL.Var.diagnose_unify_failure/5` and, if it
can explain it, records `{:constraint_violated, violation}` into
`state.diagnostics`, so `reason.message` names the constraint directly.
Scoped to the direct "one side a still-open var carrying the constraint,
other side already concrete" shape; a var-vs-var mismatch or a failure from
some other goal calling `AL.unify/3` internally doesn't get this treatment,
returns `nil` (no diagnosis) rather than guessing. Example:
`unify_failure_names_the_violated_constraint` in `e_AL_failures.ex`.

## Adding a goal

1. A compile clause in `AL.Syntax` (call → goal struct), the matching print
   clause in `AL.Syntax.Printer`, and the name in `@special` if it is a reserved
   form.
2. Add it to the `goal()` typespec.
3. An `operation/2` clause in `AL.JAM.Compiler` and its execution in the
   module that owns the concern: a relational read in `AL.JAM.Relation`, a
   durable write or driver-state effect in `AL.JAM.Mutation`, a term primitive
   in `AL.JAM.Primitive`, a constraint in `AL.JAM.Constraint`. Add the matching
   `goal/2` clause there too (and an `instruction/2` clause in `AL.JAM` for a new
   instruction shape) so traces and failure messages can show it. A mutating
   goal must **both** write the command (`AL.Command.*`) **and** apply to the
   projection (`AL.Object.*`); a read returns `{:stores, stores}` for
   alternatives.
4. If it mutates, add a case to `AL.Object.hydrate_event/3` so replay/fork works.

No comments — repo-wide ban (al-practices' "Code style"), machine code included.

## Roadmap context

README promises **bitemporality** (valid-time, not just the log's transaction-time
`t`) and easy time-travel between branch points. Forks are the groundwork;
diff/merge and valid-time queries are unbuilt.

## Known gaps

- **Arithmetic bounds consistency for `< > <= >= =`.** Both sides ground (evaluated
  arithmetic) is the original check; a side that derefs to a bare open var
  narrows an interval instead of failing (`AL.Var.add_compare/5`), living in
  the same `ConstraintSet` slot `dif`/`isa` do (`bounds :: {lo, hi}`) with its
  own `props` list of parked propagators — narrowing one var re-queues every
  other propagator on it, a worklist fixpoint (`AL.Var.run_fixpoint/3`), so
  `x < y, y < 5` tightens `x` transitively. A var whose bounds collapse to a
  single value binds outright through the existing `bind/4` (so `dif`/`isa`
  still gets checked). A compound expression with an open var still buried
  inside after evaluation (e.g. `n - 1` with `n` open) has no interval to
  narrow and hard-fails.

  `vm_label/1` (`Goal.Label`) is the companion CLP(FD) primitive: enumerates a
  still-open var's propagated `{lo, hi}` by *splicing a `between/4` send*
  (`:object`'s own recursive method), not an eager list of alternatives, which
  would build every value up front, catastrophic for a wide domain (`between` only
  computes what backtracking actually visits). `factorial`/`fibonacci`
  (`priv/programs/bootstrap.al`) collapse to one relational clause each on top of this: the
  inequalities are real invariants posted while `n` may be open, `vm_label(n)`
  is the single point concreteness gets forced either way. `fibonacci`'s bound
  (`n <= x + 1`) needs `x` wrapped in `implies`, relying on
  omitted-`:else`-is-vacuous-success (see al-practices' `implies` gotcha).
  Compound interval arithmetic (narrowing a var buried inside `+ - * /`) is
  still unbuilt. Examples in `e_AL_bounds.ex`; [[al-bounds-consistency]] for
  design history.

- **`copy_term/3`** — `copy_term Term Copy Goals` gives `Term` with fresh,
  unconstrained variables and every constraint reachable from it as ordinary
  goals over the copy (`dif`, `class`, `isa`, bounds, `in_domain`, pending
  `super`/`slot`, `map_get` keys, `functor`, linear and other arithmetic
  relations, and suspended goals). Prolog's `copy_term/3`; the way to treat a
  constrained term as data, for example when writing it out.
- **`in_domain/2`** — a real constraint (`ConstraintSet.domain :: MapSet.t() |
  nil`, alongside `dif`/`isa`/`bounds`), not a class with a `:domain` method.
  `AL.Var.add_domain/3` intersects across repeated posts; `find_violation/4`
  checks it at bind time like the other three. `vm_label`'s fallback chain
  gained a tier for it (between numeric bounds and the class-`:domain`-method
  fallback): just `member/2` over the narrowed set, no class/`SendAsValue`
  involved. Not eagerly cross-narrowed with `dif` — labeling enumerates via
  backtracking and each candidate still passes the normal bind-time check, so
  a `dif`'d value gets skipped there; sound, not maximally tight. Prefer
  non-atom domain values when the domain is conceptually "real things"
  (`:square`/`:card`-style) rather than plain symbols — a bare atom used only
  as an `in_domain` value quietly breaks the "bare atom ⇒ durable" invariant
  elsewhere in AL (`examine(:two, info)` returns nothing on an
  `in_domain`-only symbol). Examples in `e_AL_in_domain.ex`.

- **Ivar specs** — a class's `ivars:` is a list of maps, each with a `name:`
  and optionally `domain:`/`type:`/`default:`/`storage:`
  (`ivars: [#{name => suit, domain => [hearts, ...]}]`). A bare name is rejected by
  `allocate_class` and by the definition document reader. `:value`'s default
  `:init` wires checking + generation from it automatically. `domain:` posts `in_domain`; `type:` attaches `isa` so
  `vm_label`'s class-`:domain`-method fallback can generate a value. Zero VM
  changes — `ivars` was already opaque class metadata. New helper methods
  live on `:object`, not `:map` (a classed map dispatches via its own
  `:class` field, never through `:map`). `ivars: []` (every pre-existing
  value class) keeps the old default-`:init` behavior untouched. Explicitly
  deferred:
  numeric-range generation, durable
  (`:object`-super) classes. Demo in `priv/packages/blackjack/definitions/card.class.al`.

- **Dispatch legs converged to one domain-constraint mechanism** —
  mechanically done, semantically still in progress. Every leg (generative,
  durable, `in_domain`) answers the same question — "self is unbound; what's
  its domain of possible values, and how do we get a concrete one when
  forced?" — differing only in how the domain is represented: a predicate
  domain (generative: class clause heads; `isa`: a class name) vs. an
  explicit set (durable: log-scanned ids; `in_domain`: a literal set). See
  `references/dispatch-domain-unification.md` for the full design history —
  what's merged, what's still semantically open (construction-time
  invariants like a `union`'s left/right disjointness), and a concrete
  double-proof bug this closed (a bare atom durably classified into a
  `super: :value` class whose own clause matches it — now guarded at both
  classification and definition time).

- **Durable candidate generation doesn't consult `isa`/`dif` before scanning.**
  `AL.Var.bind/4` being the one choke point means a wrong-class durable
  candidate is always *rejected* correctly, but `durable_candidates` still
  enumerates and unifies every selector-matching object first — an existing
  `isa` constraint could in principle narrow the scan itself. Not built; lower
  priority than correctness, which is already there.

- **No tuple surface syntax.** AL deliberately rejects Elixir tuple literals.
  Use lists, maps, or value objects for AL data. Internal VM encodings may still
  use tuples because they are not AL values written by a program.

- **Atom-identity leak.** `fresh_id`/`gensym` mint atoms (`:"#N"`); the BEAM
  never garbage-collects atoms, and replay re-mints the same ones on top of
  whatever's already live. A long-lived node doing enough object creation
  eventually approaches the ~1M atom ceiling and dies. Fix is a non-atom
  identity scheme — invasive, needs its own design pass, not started.

- **Prior art, if extending constraints further**: CLOS generic-function
  dispatch has no analogue for "hypothesize a value for an unbound receiver"
  — it presupposes arguments already have concrete runtime classes, no
  unification/backtracking underneath. Prolog has no dispatch-by-type layer
  to hook into at all — clauses already *are* the generation policy; the
  problem AL solves here is self-inflicted by layering OO dispatch over
  logic search. Closest real precedent: **CLP(FD) `labeling(Strategy,
  Vars)`** (a pluggable policy for how an unbound finite-domain var gets
  concretized — `ff`/`min`/`max`/`bisect`) plus attributed-variable hooks
  (`attr_unify_hook/2`, `verify_attributes/3`, `freeze/2`).

## Operand access and substitution profiling

`AL.JAM.IR.Access` specifies shallow versus deep input access, exposed in
`IR.Inference.access` and shared by primitive argument resolution and local
assignment/disequality execution. Shallow access follows the root reference;
it does not freeze or copy nested fields. Unknown operations retain deep access.
Equality inspection (`equal`, `variant`) still resolves nested values. Functor
operations preserve field references and let `AL.Var.add_functor` perform
structural unification and constraint propagation.

`AL.JAM.Unification` preserves the original operand references when binding a
variable, retaining `AL.Var.bind` occurs checks, constraint checks, and ground
marks. Structural comparisons still resolve compound/map frontiers. JAM's
`dif` probes this incremental unifier and materializes terms only when it needs
to retain a deferred disequality. Caller syntax and public protocols are unchanged.

`bench/parse_substitution_profile.exs` attributes recursive substitution visits
to their outermost caller. On the 172-byte point fixture, the operand-access
changes reduced visits from about 86,000 to 21,000 per parse; a sequential
same-process comparison measured 1.60M to 1.51M reductions and 15.9 to 14.4 ms.
These are workload-specific measurements, not an order-of-magnitude speedup.
The final runtime passed 876 tests, including aliasing, map-key resolution,
occurs checks, deferred disequalities, and both functor directions.

Callable invocation now passes argument references into head matching. Bound
argument-list spines are followed incrementally by `Head.match_arguments`,
including lists held in registers; unresolved tails retain the generative
fallback. The fallback resolves the spine without traversing argument values.
IR access summaries mark a callable's third operand as `:reference`. Capture
environments still substitute and freshen unbound fields per invocation;
sharing those fields directly would change callable semantics.

This follow-up lowered substitution visits from 21,134 to 12,396 on the point
fixture, with about 0.9% fewer reductions (1.509M to 1.496M). The full suite
passed 879 tests, including open argument tails, nested aliases, and argument
spines across backtracking. This is a small argument-passing improvement;
substitution visit counts should not be mistaken for total runtime savings.

## Callable boundaries inside regions

`IR.Inline.callables/2` runs before region/dataflow specialization and instruction
selection when compiling ordinary methods. A statically known callable with
identical head/argument lists of variables can be expanded into its primitive
IR operations. Parameters retain caller references; body-only variables get
separate names only when dataflow proves they have not previously escaped.
Previously exposed captures, different head/argument layouts, control scopes,
dynamic bodies, and sends inside the callable retain the callable boundary.
No runtime variable values or grammar-specific names participate in this rule.

The shared IR then allows numeric exclusions (`dif` against numeric constants)
to join comparisons in the existing `numeric_tests` instruction. Open and
nonnumeric operands, tracing, and constrained step budgets execute the original
instructions. Failure retains the failing source operation and logical step
count. Trace-enabled method fetches use a separate transaction-cache entry
compiled without callable inlining, preserving call events after an optimized
cache has been warmed; method edits invalidate both views.

On the 172-byte point fixture, three identical profiled samples showed callable
executions falling from 1,277 to 127 and frame entries from 3,304 to 2,154, with
1,561 sends unchanged. Entries include prepared alternatives. Sequential runs
of 31 timing samples measured 1.499M to 1.184M reductions (21% lower) and median
14.722 to 12.595 ms. `bench/parse_region_profile.exs` reproduces execution counts.
The complete suite passed 889 tests. Recursive sends are still calls; this pass
does not introduce loop jumps or remove general choicepoints.

### Provider fusion inside a known callee

`IR.Plan.inline/5` applies the existing provider-prefix fusion before accepting
an inlined callee. Provider guards and source dependencies are retained only
for accepted candidates, alongside the normal target dependency. The existing
context restrictions, variable renaming, alternatives, and fuel limit still
apply. This allows an inherited method inside a recursive region to lose its
call boundary without changing the recursive relation into a deterministic
loop.

For the point fixture, three identical count samples measured 1,413 sends and
2,006 prepared frames, down from 1,561 and 2,154 respectively. All 148 removed
frames were `symbol_code` entries. Reductions fell from approximately 1.184M to
1.152M (2.7%). `parse_region_profile.exs` now reports entries by selector;
these include prepared clause alternatives, not only executed calls or live
stack depth. The full suite passed 890 tests, including nested-provider open
arguments, constraints, alternatives, and invalidation after inherited edits.

### Cost of unused alternative preparation

The parser search profiler now attributes approximate head/local and entry
preparation reductions to created and resumed dispatch alternatives, including
entries that forward outputs directly. It reports missing attribution and
per-sample unused costs. Measurement overhead and instrumentation-induced GC
make these estimates unsuitable as claimed runtime savings.

On the point fixture, three warm samples consistently created 597 alternatives,
resumed 460, and left 137 unvisited. All alternatives had cost attribution.
Unused preparation measured 20,986, 27,652, and 20,987 reductions against an
uninstrumented 31-sample baseline of 1.161M reductions per parse. Most prepared
alternatives execute; the unused preparation accounts for roughly 2–3% of the
parse before any lazy-choice overhead. Lazy alternative preparation was not
implemented. The stronger target remains eliminating repeated head/local
setup through larger specialized regions. This investigation changed profiling
only; parsing results were checked across all profiled and timing samples.

### Larger-region alternatives experiment

An experiment composed multiple statically matched callee clauses as choices
inside one IR region, avoiding the planner's rejection of an increased caller
clause count. A separate experiment expanding branch arms removed no sends and
was discarded first. Choice composition passed 52 focused tests, including
ordered duplicate answers, caller constraints, cut scope, and nested conditions,
but did not improve parser reductions; it was also reverted.

For the point fixture, three repeatable count samples showed sends decreasing
from 1,413 to 1,318 and prepared entries from 2,006 to 1,909. Clause-head attempts
fell from 2,798 to 2,684, successes from 1,996 to 1,882, with 802 failures unchanged.
Total matched-frame register slots fell from 10,554 to 10,091, but fresh locals
initialized increased from 2,412 to 2,491 and VM branch instructions from 91 to
360. These are execution/initialization counts, not allocation bytes or counts
of necessary logical decisions. The removed frames were mainly match_pattern,
sequence, gap, and blanks. Two extra head_rest frames offset some removals.

Sequential 31-sample runs measured 1.158M reductions for the previous planner
and 1.169M for choice composition. This experiment demonstrates removable call
boundaries, not a net optimization: removing successful head setup can trade
its cost for explicit branching and eager branch-local initialization. Future
larger-region work should preserve efficient clause selection and avoid eagerly
initializing locals for all arms. The retained parse_region_profile counters
expose these distinctions; no experimental planner/runtime changes remain.

### Deferred branch-local initialization follow-up

A follow-up prototype deferred only locals exclusive to one branch, excluding
head variables, captures, sibling references, and references after the join.
Right-arm locals were initialized when the saved alternative resumed; its
fresh scope was reserved in the saved entry. The prototype used internal branch
code metadata, and did not introduce an AL primitive. It was tested alone and
with the larger-region choice composition experiment, then completely reverted.

For the larger regions, eager local initialization fell from 2,491 to 2,156,
but 298 deferred locals were subsequently initialized: only 37 initializations
were avoided. Three profiled parses agreed and preserved results. The combined
experiment measured 1.172M reductions. A further conservative policy retaining
multi-clause calls with unresolved first-operation rejection tests measured
1.185M. This policy could also withhold previously accepted inlining, so it is
not an isolated measurement of clause-selection overhead. Deferred locals alone
measured 1.158M. After restoring all seven experiment files exactly, the normal
parser measured 1.156M reductions and matched the native reader. These were
11-sample measurements, not evidence of a timing improvement.

The focused experimental run had 49 passing tests and one structural assertion
expecting the old planner's inlined count; it was not a fully validated runtime
change. No experimental runtime or profiler modifications remain. The result
rules out eager branch-exclusive local initialization as a substantial source
of cost for this fixture; it does not establish a general limit on region
compilation or classify required unification as avoidable work.

### Source-attributed boundary accounting

`bench/parse_boundary_profile.exs` records optimized sends by caller method,
PC, selector and operand facts; maps prepared/resumed dispatch alternatives to
source clause identities; and exports an ordered send path and clause bodies
with BENCH_JSON. Three warm samples must agree and preserve answers. It makes
no compiler/runtime changes. See `bench/README.md` under Parser boundary
accounting for the source locations, full classification and residual design.

On the point fixture, 1,289 of 1,413 selectors are literal JAM operands. Runtime
receivers are 1,320 al_grammar values, 89 lists and four class atoms; only 112
receiver operands are literal. Observed receiver identity is not a compiler
proof of invariance. The 460 resumed alternatives split into 230 repetition
stop clauses, 74 pure next-forwarding expression clauses, 112 integer/symbol
interpretation clauses, and 44 other grammar alternatives. The 74 forwarding
frames are implementation traversal; their destination grammar choices still
have to survive. This classification concerns source roles, not a proof that
all candidates in the other groups are necessary or viable.

The first point token takes 40 sends before declaration proceeds to gap. The
variable interpretation scans and checks point/poin/poi/po/p, all beginning with
lowercase p, then the other symbol interpretation scans again. This is a
concrete connected-region target: guard finite ground character input, fresh
unconstrained output and provider definitions; propagate first-character facts;
retain ordered shorter-prefix answers while removing repeated classification,
forwarding, dispatch, argument construction and proven progress checks. The
40-send invocation is a design target, not a measured speedup or a whole-parser
promise. Missing compiler capabilities include residual structural head actions,
mode/freshness facts across safe operations and recursive region edges. Plain
AL equality cannot replace structural head unification.

### Inferred prefix-scan region

`IR.Plan.compile_ir/4` now returns residual clause programs and their dependency
plan before register allocation/selection. `IR.Scan.compile/3` consumes that
boundary and loaded method IR to recognize a narrow family of atom-producing
prefix scans. It checks one-cell consumption, recursive argument relationships,
the empty stop clause and its order, conversion flow, and inherited classifier
and rejection shapes. No grammar selector names occur in this pass. Its result
contains classify/scan/ordered-answer/bind blocks, a finite ground character
input/fresh outputs contract, and source/provider/class guards. Unsupported
shapes produce no plan. This is structural recognition, not a general recursive
region optimizer.

The symbol benchmark now supplies only the entry receiver and selector and
executes the inferred description using its existing benchmark-only model.
All 53 first/all-answer oracle cases and 11 unsupported-input cases passed.
The inferred model measured 756 reductions for the first point answer and 1,933
for all five; the AL query measured about 78k/116.5k, including AL transaction
bookkeeping. No whole-parser speedup is claimed and Scan is not installed in
JAM dispatch. Runtime mode guards, budgets, tracing and generic fallback still
belong to the pending integration.

64 focused tests passed, including changed exclusions, renamed relations,
clause order, duplicate alternatives, effects and helper/provider/root-target
invalidation. A new root-target replacement test found an existing Plan.valid?
bug: provider_cursor was called with an obsolete target. Validation now checks
the target first and rejects that stale plan instead of raising.

Lowering the cyclic region to normal JAM remains pending explicit approval
under this skill's machine-primitive rule. The concrete proposed generic
support is move, ground get_cons with a failure edge, jump with parallel value
transfers, and try with a resumable block address/live environment. Existing
numeric tests, conversions, unification and return logic remain applicable.
No new machine instruction, AL goal or native has been added in this step.

### Generic region execution (approved)

The user approved the proposed generic machine instructions. JAM now executes
move, ground/raw get_cons with a failure edge, jump with parallel register
transfers, and try with a saved block address/live registers/store. IR.Code
assembles labels; AL.JAM.Scan lowers the inferred Scan blocks into those
instructions. Existing numeric tests, conversions, unification and return
machinery are reused. The send path selects this region for the proven input
mode, with ordinary dispatch for unsupported modes, pending suspensions and
tracing. No AL surface goal, grammar-specific opcode or native was added.

Each consumed prefix saves an ordered alternative. Invalidated saved region
continuations run the captured generic post-scan suffix, rather than reuse stale
classification results. Tests mutate the negation helper after the first answer
and then backtrack, checking duplicate answers and changed remaining-input
bindings. Guard tokens avoid hashing whole plans in the transaction cache; a
newly validated entry seeds its token, while normal source invalidation clears
it. Region code is independent of invocation slots and runtime variable IDs.

The former benchmark-only scan implementation is removed. Its helper executes
emitted JAM; symbol_region compares ordinary AL queries with region entry
locally disabled/enabled, restoring the module afterward. parse_file supports
BENCH_COMPARE_REGIONS=true for the same isolated comparison. There is no
production disable flag or separate legacy interpreter.

A 31-sample one-scheduler comparison measured point symbol first/all at
78,706/116,245 reductions without regions versus 35,033/38,114 with regions.
The full point file measured 1,174,967 versus 817,703 reductions and median
18.208 versus 11.982 ms. Unlike the earlier 756/1,933 model estimates these
include normal query/transaction and guard-validation overhead. Three count
samples agreed: 936 sends, 1,305 ordinary entries, 16 region entries and 47
saved region alternatives. Ordinary register/local counters exclude regions.

The full suite passed 906 tests after instruction integration; later focused
checks cover the final guard-token caching change and actual JAM benchmark
helper. See bench/README.md for current commands and limitations.
