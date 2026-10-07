# AL architecture map

Use this map to locate authority, follow a change through the system, and avoid
reconstructing cross-module contracts from individual call sites.

## Execution path

```text
AL source text
  -> AL.Syntax reads AL source, captures exact definition ranges, and compiles
     straight to AL.Goal structs
  -> AL.Source prepares retry-stable source metadata
  -> AL.eval_program opens one Mnesia transaction and creates AL state
  -> AL.JAM.IR lowers executable bodies to block programs
  -> IR transformations specialize regions and inline proven calls
  -> AL.JAM.Compiler allocates registers and emits machine code
  -> AL.JAM runs it; AL drives the choicepoints it yields
  -> AL.JAM.Mutation applies durable mutation instructions
       -> AL.Command appends the command with tx_id and system time
       -> AL.Object updates the branch projection using that same time
       -> AL.Source anchors captured source spans to written commands
  -> commit or abort
  -> transaction object and retained source remain inspectable
```

`AL.eval/4` starts from already-lowered goals and normally has no retained
source. `AL.eval_source/3` and `AL.eval_captured/6` carry source metadata through
the same evaluator.

## Authority and projections

| Concept | Durable authority | Structured read boundary | Derived consumers |
|---|---|---|---|
| Commands and transaction order | `AL.Command` command-log tables | `AL.Command` | hydration, outbox, transaction views |
| Classes, supers, methods, clauses, native declarations | command log | `AL.Object` over branch `soa` | dispatch and resolution caches |
| Object slots | command log | `AL.Object` over branch `aos`/`soa` according to ivar storage | dispatch, object views |
| Retained source text and definition spans | source-related commands | `AL.SourceStore`, `AL.Source` | GT views, serialised files |
| Definition documents | command log plus source projections | `AL.Definition.Snapshot` | packages, tooling |
| Source edit transaction plan | snapshot plus edited documents | `AL.Definition.Changes` | package activation |
| Resolution memoization | none | `AL.ResolutionCache` | dispatch only |

The command log owns history. A table projection may expose transaction-time
history, but it does not replace the command that produced it.

## Core modules

| Area | Start with | Continue into |
|---|---|---|
| Evaluation state and choicepoints | `lib/AL.ex` | `lib/AL/jam.ex`, `lib/AL/jam/`, `lib/AL/trace/domino.ex` |
| Answer presentation and failure reports | `lib/AL/answer.ex`, `lib/AL/diagnostics.ex` | trace and residual constraints |
| Goal definitions and storage safety | `lib/AL/goal.ex` | `lib/AL/syntax.ex`, `lib/AL/jam/mutation.ex` |
| Dispatch and method order | `lib/AL/dispatch/dispatch.ex` | `lib/AL/dispatch/`, `lib/AL/cache/` |
| Terms, variables, and constraints | `lib/AL/term.ex`, `lib/AL/var/var.ex` | `var/store.ex`, `var/unification.ex`, constraint modules |
| Projection storage access | `lib/AL/mnesia.ex` | literal-safe match specifications and exact deletion; keyed reads in `AL.Object` |
| Durable writes and replay | `lib/AL/command_log/command.ex` | hydration modules, `lib/AL/view/object.ex` |
| Branch creation and isolation | `lib/AL/branch.ex` | command/view table naming and copying |
| Source reading, capture and printing | `lib/AL/syntax.ex` | `lib/AL/syntax/printer.ex`, `lib/AL/view/source.ex`, `source_store.ex` |
| Definition serialisation codec | `lib/AL/definition/document.ex` | `definition/path.ex`, `definition/snapshot.ex`, `definition/changes.ex` |
| Package bundle writing | `lib/AL/package/export.ex` | definition documents and filenames |
| GT inspection | `lib/AL/gt_bridge.ex` | `lib/AL/view/` |
| Bootstrap language behavior | `priv/programs/bootstrap.al` | `lib/AL/transaction_program.ex` and `al-practices` |
| Package object protocol | `priv/programs/package_system.al` | `lib/examples/e_AL_packages.ex` |
| Host package discovery | `lib/AL/package/discovery.ex` | package catalog/channel/provider structs and document codecs |
| Package resolution | `lib/AL/package/resolver.ex` | the AL package resolver object, build specs, and content addresses |
| Package orchestration and import | `lib/AL/package.ex` | `package/composition.ex`, `package/activation.ex`, `package/publication.ex`, and the package object protocol |

## Durable mutation checklist

Follow one mutation from syntax to replay before changing it:

1. `AL.Goal.*` defines the runtime shape.
2. `AL.Syntax` compiles AL source to that goal and `AL.Syntax.Printer` prints it
   back.
3. `AL.JAM.Compiler` compiles it to a `{:mutation, …}` instruction and
   `AL.JAM.Mutation` validates durable values and performs the write.
4. `AL.Command` records the operation and transaction identity.
5. `AL.Object` updates or closes the matching projected fact.
6. `AL.Source.anchor` associates a captured definition with the command time.
7. hydration/replay recognizes the command and rebuilds the same projection.
8. cache invalidation covers every query whose answer changed.

If the change affects only a read or a derived format, it should usually stop
before this path rather than inventing a new durable command.

## Method model

A method is not one row:

```text
owner + selector --method binding--> method_id
method_id + clause sequence --------> head + body
command time -----------------------> retained source span, when captured
```

Imports may intentionally share a `method_id` across owners. Editing clauses on
that ID changes every binding that points to it. Removing one binding must not
remove shared clauses while another binding remains. Clause sequence determines
resolution order.

## Branch model

- Every mutable/readable projection is branch-specific.
- A fork copies history through a chosen transaction point and then diverges.
- Work that tests AL behavior should normally create and discard a fork.
- A test that needs an empty installed world can fork main at transaction `0`
  and install current packages there.
- Outbox behavior is tied to committed branch commands; inspect outbox
  ownership and commit notification before changing fork behavior.

## Source model

```text
transaction source_text
  + source_span keyed by command time
  + live method/class projection
      -> AL.Source resolves retained text or decompiles
      -> AL.Definition.Snapshot builds owner documents and diff facts
      -> AL.Definition.Document renders/parses the file format

edited documents + old snapshot
      -> AL.Definition.Changes.plan/3
      -> source chunks + direct prefix goals
      -> AL.Definition.Changes.compile/1 produces goals and source metadata
      -> AL.Package evaluates the activation transaction
      -> new command/source facts
      -> regenerated documents
```

Metadata such as metaclass, supers, ivars, selector, method ID, and clause order
comes from tables. Only a method body claims to be retained source. A document
revision is an optimistic concurrency check against its snapshot.

## Fast inspection routes

- Find a goal: search its struct in `goal.ex`, then its `AL.Syntax` compile clause and its
  lowering in `AL.JAM.IR`/`IR.Lower`, then instruction selection in `IR.Emit`.
- Find a durable operation: search the operation atom in `AL.Command`,
  `AL.Object`, hydration, and cache invalidation.
- Find a source discrepancy: inspect `AL.SourceStore.text/2`, its span at the
  command time, then `AL.Source.method_clause_source/5`.
- Find a dispatch discrepancy: inspect direct classes/supers/method bindings,
  then `AL.Dispatch.MethodOrder` and relevant resolution-cache entries.
- Find a package definition discrepancy: compare `AL.Definition.Snapshot.capture/1`, parsed
  `AL.Definition.Document`, and `AL.Definition.Changes.plan/3` against the package activation plan.

## Verification

Use the smallest relevant test first:

```console
.agents/skills/al-internals/scripts/test.sh test/definition_changes_test.exs
.agents/skills/al-internals/scripts/test.sh test/definition_document_test.exs
.agents/skills/al-internals/scripts/test.sh
```

The script selects a fresh local Mnesia directory. It does not reset or touch
the checkout's normal store.
