(:autolith-skill
 :version 1
 :name "al-development"
 :description "Develop and investigate AL using its relational semantics, durable runtime, and Autolith's Common Lisp, RLM, worker, memory, and agent facilities."
 :instructions
 "# AL development

Use this skill for design, investigation, implementation, testing, and review in the AL repository. AL is a live, ACID, eventually bitemporal relational-object system implemented in Elixir. Its north star is a personal computing environment, and its current runtime combines an append-only command log, derived object projections, relational dispatch, backtracking, finite-domain constraints, branches, and derivation traces.

For detailed interpreter facts, consult `.claude/skills/al-internals/SKILL.md` as repository documentation. Retrieve only the sections relevant to the task, preferably through a bounded RLM inference rather than loading the complete file into the primary conversation. Verify detailed claims against current source.

## Semantic frame

Treat these as the default invariants to verify:

- `AL.Command` is authoritative history; `AL.Object` is a derived projection.
- Durable mutation must append an event, update the projection, and replay through `AL.Object.hydrate_event/3`.
- Interpreter execution is transactional. Failure must not leave partial durable state.
- Preserve bidirectional execution, backtracking, choicepoint isolation, caller-visible bindings, and clause order.
- Keep durable retrieval distinct from generative construction.
- Object creation is `construct -> allocate -> init`.
- Branches isolate command logs, projections, resolution caches, and schedulers.
- Check cache invalidation, hydration, branch lifecycle, and tracing whenever durable resolution data changes.
- Valid-time bitemporality, branch diff/merge, and compound interval arithmetic are roadmap items unless current source proves otherwise.

Classify a problem before editing:

- surface lowering: `lib/AL/lowering.ex`
- interpreter stepping: `lib/AL.ex`
- mutation: `lib/AL/interp/store.ex`
- relational reads: `lib/AL/interp/relations.ex`
- choicepoint control: `lib/AL/interp/control_flow.ex`
- dispatch: `lib/AL/dispatch/dispatch.ex`
- resolution order: `lib/AL/dispatch/method_order.ex`
- variables and constraints: `lib/AL/var/`
- durability, replay, and forks: `lib/AL/durable/`
- derivations: `lib/AL/trace/`

## Lisp laboratory

Use Common Lisp as an executable semantic notebook when it improves the work. AL remains the source of truth and production changes remain Elixir.

Represent unfamiliar mechanisms as small S-expressions before implementation. Useful shapes include:

```lisp
(:send ?receiver :selector (?arg ...))
(:event system-time tx-id (:set-slot object key value layout))
(:choicepoint :goals (...) :store (...) :alternatives (...))
(:trace (:method-call scope receiver selector args constraints) ...)
```

Use these representations to expose binding scope, ordering, replay boundaries, and state transitions. Prefer:

- `lisp.eval` for one focused executable experiment;
- a conversation scratchpad plus `lisp.scratchpad-run` for multi-form prototypes;
- a named `al-research` worker when an investigation benefits from persistent definitions;
- assertions over examples, counterexamples, and invariants rather than prose-only reasoning.

Common Lisp is particularly suitable for prototyping unification, substitution, graph traversal, method ordering, fixpoint propagation, trace folding, and event replay. Translate successful prototypes into focused Elixir tests before production code. Do not create a Lisp model merely to mirror straightforward Elixir code.

Use RLM for large traces, design documents, or repository-wide semantic questions. Keep bulky evidence external and bring back conclusions, counterexamples, and exact source locations. Use child agents for independent investigation or review; keep one agent responsible for interconnected edits.

Self-modify Autolith only when recurring AL work exposes stable workflow friction, such as a missing trace summarizer or test command. Prototype and exercise the change, inspect `self.diff`, and either discard it or persist it deliberately. Never confuse private Autolith mutations with AL repository changes.

## Investigation workflow

1. State the behavioral contract and the AL invariants it touches.
2. Reproduce before editing. Prefer a disposable AL branch or isolated Mnesia store.
3. Use existing structured traces before adding instrumentation: `run vm_trace: true do ... end`, `AL.Trace.render/1`, failure diagnostics, and `reason.state`.
4. Reduce the failure to the owning subsystem.
5. For a subtle semantic change, build a minimal S-expression model or executable Lisp counterexample.
6. Design the smallest complete vertical change. For durable behavior, include event, projection, hydration, cache, branch, and trace consequences.
7. Implement in the owning Elixir module and add tests that exercise direct and relational execution where applicable.
8. Review what capability the design forecloses, not only what it enables.

For a new goal, normally check lowering, the `goal()` type, the owning `interp/2` implementation, delegation from `AL.interp/2`, durable event handling when it mutates, and replay/fork behavior.

## Runtime isolation

For work against the existing shared `.mnesiastore`, use full Autolith command permissions, ensure EPMD is running, and retain AL's default distributed mode:

```sh
epmd -daemon
mix test
```

For isolated or CI-style work, use a fresh Mnesia directory and disable distribution:

```sh
store=$(mktemp -d)
AL_MNESIA_DISTRIBUTED=false AL_MNESIA_DIR=\"$store\" mix test
rm -rf \"$store\"
```

Never point non-distributed mode at the existing distributed store. Give concurrent agents distinct Mnesia directories. Within AL, prefer `AL.Branch.fork_fresh/2` and `run branch: branch.id do ... end`; discard disposable branches after use and avoid changing HEAD unnecessarily.

## Verification

Run focused tests first, then the repository CI sequence:

```sh
mix format
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix dialyzer
```

Use the appropriate Mnesia mode above. Verification should cover the affected dimensions among normal execution, failure and transaction abort, backtracking, bidirectional calls, constrained variables, replay and hydration, fork isolation, dispatch miss versus query failure, cache behavior, and trace reconstruction.

Before completion, ask an independent reviewer to search for a patch that works directly but fails under backtracking, replay, hydration, fork isolation, open-receiver dispatch, constraint propagation, or transaction abort.

Inspect the final diff, preserve unrelated work, stage only task files, and commit after relevant checks pass. Record stable architectural decisions in workspace memory, current commitments or blockers in the agenda, and reusable procedure in this skill or repository documentation.")