# Language benchmarks

Run from the repository root:

```sh
mix run --no-start bench/parse_file.exs
mix run --no-start bench/bnf.exs
```

| Benchmark | Work measured | Correctness check |
|---|---|---|
| Parse file with AL.Syntax | Tokenize and parse `fixtures/point.al` using the native source reader | Full parsed result remains identical |
| Parse file with AL grammar | Execute `parse al_grammar (program Items) Source` through AL, including transaction overhead | AST matches the native reader after normalizing variable representation and method reconsult directives |
| Generate complete BNF | Extract grammar rules, find reachable rules, and render the BNF for `al_grammar`'s `program` rule | Exact text matches `lib/AL/syntax.bnf` |

The default parsing fixture is a 172-byte class declaration with two methods.
It is parsed without installing or executing its declarations. Pass another
file to exercise a different input:

```sh
mix run --no-start bench/parse_file.exs path/to/source.al
```

The AL grammar and native reader support different syntax coverage; a file
must be supported by both for this cross-check to pass.

Each command creates and cleans up a private Mnesia store. Runtime startup,
file reads, three warmup runs, output checks, and explicit garbage collection
are outside the measured interval. Reports include median/minimum/maximum
milliseconds and mean BEAM reductions across 11 samples. The two parsers
measure distinct implementations; their timings are reported separately.

```sh
BENCH_SAMPLES=21 BENCH_JSON=/tmp/parse-results.json mix run --no-start bench/parse_file.exs
```

Compare runs on the same machine with the same fixture and sample count.
Reductions are generally steadier than wall time. These workloads replace the
JAM instruction microbenchmarks; existing application examples such as
Fibonacci and Sudoku remain available separately.

## Atom growth

```sh
ELIXIR_ERL_OPTIONS='+S 1:1 +t 4000000' BENCH_JSON=/tmp/atom-growth.json mix run --no-start bench/atom_growth.exs
```

This warms and repeats object creation, definition snapshot rendering, and their
combination in one VM, using a temporary Mnesia store. The old filesystem
synchronizer and branch-tree exporter have been removed. Earlier parser
benchmarks disabled synchronization and therefore did not measure its atom
growth or execution cost.

Before the query-variable fix, each warmed `new object X` added three atoms.
A full definition serialization added 1,336 more: the loaded branch had 668
clause-source reads, each creating a unique `source_head_<scope>` and
`source_body_<scope>` atom. Together these reproduced exactly 1,339 new atoms
per invocation. Compiled, pre-parsed, source-evaluated, and dynamically compiled
calls had the same three-atom execution growth without serialization.

Source queries and direct-class checks now use existing fresh-variable tuples
with fixed base names. Repeated definition serialization adds zero atoms;
object creation, with or without serialization, adds two for the object and
transaction identities. This fixes these temporary-name leaks; source variable
names are still atoms pending the separate binary-name migration.

The former synchronizer marked definitions dirty for every source-text or
object-table event. Its startup/branch hooks, filesystem layout, and standalone
exporter have been removed. Shared definition code now lives in `AL.Definition`;
filesystem exports go through `AL.Package.export/2`.

## Parser function profile

```sh
mix run --no-start bench/parse_profile.exs [file.al]
```

Profiles five warm parses with OTP's `eprof`, verifies every result against
`AL.Syntax`, and writes function counts and exclusive times to
`/tmp/al-parse-profile.txt`. Set `BENCH_PROFILE` to choose the output path.
The profile excludes file reading, startup, warmup, and result verification.
Use `parse_file.exs` for timing; profiler overhead is substantial.

## Parser substitution profile

```sh
mix run --no-start bench/parse_substitution_profile.exs [file.al]
```

Counts recursive substitution visits during one warm parse and attributes them
to the outermost substitution caller, with a short stack and source locations.
Nested substitution calls remain attributed to their initiating caller. The
instrumented result is checked against the warmup result. Instrumentation is
loaded only into the benchmark process; runtime files are not edited. These
counts exclude result display and are not timing measurements.

## Parser binding profile

```sh
ELIXIR_ERL_OPTIONS='+S 1:1' BENCH_JSON=/tmp/bindings.json mix run --no-start bench/parse_bindings_profile.exs
```

Accepts an optional source file. Instruments `AL.Var` and the JAM equality
boundary inside the isolated benchmark process. Three warm samples must agree
and preserve the complete query result. Counters cover variable dereference
lookup depth, fresh-variable origins, attempted binding writes, selected direct
store reads in `AL.Var`, and occurs/groundness list traversal. They do not count
all map operations across the runtime, successful retained bindings, or heap
allocations. Timings of this instrumented run are not meaningful.

On the point fixture after consumption-region compilation, before direct output forwarding:

| Counter per parse | Count |
|---|---:|
| Variable dereference requests | 8,030 |
| Requests using one / two store lookups | 7,966 / 64 |
| Maximum observed dereference depth | 2 |
| Instrumented direct store reads in `AL.Var` | 11,115 |
| Attempted binding writes | 1,302 |
| Binding writes to variables minted as clause-frame locals | 894 |
| Fresh clause-frame locals | 1,278 |
| Largest store observed before a binding write | 620 entries |
| Substitution term visits, separate substitution profile | 3,072 |
| Occurs/groundness list-cell visits | 17,633 |

Of those list-cell visits, 8,008 occur at consumption-region equality exits,
1,545 at symbol-region exits, 6,431 at ordinary JAM equalities, and 1,649
elsewhere. The loops execute with registers but still bind output variables
through general unification. `send_local` and `returning_entry` already support
some direct outputs; at the time of this profile, region entry used a plain return continuation.
This suggests extending output forwarding and preserving proven freshness and
groundness across call boundaries before replacing the variable store.

Local allocation origin does not prove non-escape: those 894 writes are
candidates for analysis, not 894 safely removable writes. Consumption admission
only proves a prefix and stopping element, so it does not prove the untouched
suffix ground or free of the output variable. Occurs checks must remain unless
stronger compiler/runtime facts justify elision.

A separate five-parse `eprof` run attributed approximately 18.7% of exclusive
instrumented time to `AL.Var`, including 1.9% to `scan_list`. Helper map/enum
work and GC are not attributed to that module. These percentages are diagnostic,
not uninstrumented wall-time fractions or evidence of a twofold speedup.

## Parser region profile

```sh
mix run --no-start bench/parse_region_profile.exs [file.al]
```

Counts executed sends, callable invocations, numeric-test groups, and frame
entries by selector over three warm parses. Entries include prepared clause alternatives;
they are not a count of live stack depth. Checks that samples agree and results
match the warmup. The benchmark instruments JAM in its own process with checked
source hooks. Use `parse_file.exs` for timing.

It also counts clause-head attempts and successes, total register slots in
successfully matched clause frames, fresh locals initialized for those frames,
and executed VM branch instructions. Prepared register slots measure frame
width, not the number of register writes. These counters distinguish reduced
call-boundary setup from work moved into larger frames or explicit branches;
they do not classify all remaining unification as eliminable overhead.

## Parser search profile

```sh
mix run --no-start bench/parse_search_profile.exs [file.al]
```

This reports dispatch alternatives created, resumed, unvisited, and resumed
alternatives that fail on their first instruction, grouped by selector. Three
warm samples check that counts agree and parsing results remain unchanged.
It also estimates reductions spent matching heads, initializing locals, and
building entries, attributing preparation to created and resumed alternatives.
The difference estimates preparation spent on unused alternatives. These costs
include measurement-call overhead and can be affected by instrumentation-induced
garbage collection; they are diagnostic estimates, not benchmark speedups.
`unmeasured_alternatives` must be zero for complete cost attribution.
It temporarily instruments JAM in the benchmark process, checks its source
hooks, and rejects ambiguous snapshot identities. It does not edit runtime
files or add production profiling overhead. These counts cover ordinary send
and `next` clause alternatives, not all control-flow choices. Unvisited
alternatives are not necessarily dead. Failures inside a nested call are not
counted as first-instruction failures of its caller. Use `parse_file.exs` for
timing; instrumentation overhead makes profile timings unsuitable for comparison.

## Parser boundary accounting

```sh
BENCH_JSON=/tmp/parse-boundaries.json mix run --no-start bench/parse_boundary_profile.exs
```

Accepts an optional source file. Instruments optimized JAM in the benchmark
process, records three warm parses, and rejects inconsistent counts or changed
answers. The JSON includes send sites with literal operand facts, sampled
runtime argument shapes, the ordered send path, alternative clause identities,
and their stored source bodies. Runtime samples are observations, not compiler
proofs. It automatically identifies clauses whose entire body is `next`.
Instrumentation timings are not performance measurements.

### Point fixture findings

The 172-byte fixture executes 1,413 sends: 1,289 have literal selectors in JAM;
124 use register selectors. Of the observed receivers, 1,320 are
`#{class => al_grammar}`, 89 are lists, and four are the class atom
`al_grammar`. Only 112 send instructions have a literal receiver operand.
These facts distinguish already-fixed selectors from receiver information that
would have to be propagated or guarded across a larger region.

Source-attributed resumed alternatives total 460:

| Family | Resumed | Interpretation |
|---|---:|---|
| `blanks` stop / `zero_or_more` stop | 125 / 105 | Relational prefix/termination choices; preserve unless invocation and continuation facts rule them out |
| `map_syntax`, `block_syntax`, `string_syntax` expression fallback | 25 / 25 / 24 | Bodies contain only `next`; provider forwarding can become control-flow edges, while preserving the grammar alternatives reached |
| `integer` alternative | 55 | Positive/negative recognition or generation; input-mode and character tests can specialize selection |
| `symbol` alternatives | 57 | Numeric/atom/variable interpretation with inherited recognition and rejection tests; mixed semantic search and implementation traversal |
| Other grammar alternatives | 44 | Delimiters, collection structure, optional forms, and expression forms; not established as removable |

The 74 forwarding resumes are not 74 proven removable logical choices. Their
extra provider frames are the removable layer. Conversely, a stop alternative
is not necessarily viable: earlier profiling found 34 `blanks` resumes failing
immediately on equality. Those require invocation-level alias facts before
pruning, not a blanket commitment to greedy consumption.

### One concrete recursive path

The first `point` token follows 40 sends, from `declaration -> symbol` until
the subsequent `declaration -> gap` send. It first attempts integer recognition,
then scans the token and checks `variable_name` for `point`, `poin`, `poi`, `po`,
and `p`. All share lowercase `p`. It scans again through the other inherited
symbol alternative, checks `unless(variable_name(point))`, and checks
`unless(integer_name(point))`. These checks invoke `within`, `match_pattern`,
`sequence`, and argument-list `concat` along the way.

The relevant source is `priv/programs/bootstrap.al`: repetition at lines
1201–1208, symbol recognition at 1369–1381, number classification at 1461–1483,
and variable classification at 1487–1495. `within` is at 1193–1195 and
`match_pattern` at 1155–1177. The trace JSON supplies the expanded clause bodies
created by those source rules.

### Residual region design

The proposed first target is the connected symbol-recognition region for a
guarded finite ground character-list input and a fresh unconstrained output.
Guard receiver/provider definitions and retain the generic relation for other
modes, constrained outputs, or invalidated assumptions.

1. Classify the first character once. For `p`, reject the numeric and variable
   interpretation paths using facts derived from their AL definitions.
2. Traverse the symbol characters with input-tail and output-span registers.
   Keep the required character exclusions. Strict one-element consumption of
   an acyclic ground list proves progress, replacing repeated progress checks.
3. Preserve stop/resume states for shorter prefixes in the original order.
   Retain all distinct valid outputs and duplicate answers required by source.
4. Materialize and bind an atom at an answer boundary. On continuation failure,
   resume at the next prefix without redispatching the grammar wrappers.

This targets one guarded region entry in place of that 40-send invocation,
not one instruction and not a measured speedup. Atom conversion, required
matching, and backtracking remain. Sharing recognition across provider branches
requires proofs of purity, freshness, answer order, and preserved failures;
moving arithmetic or binding operations past a guard is not automatically safe.
All facts must come from AL IR and primitive contracts, not grammar names in JAM.

The current planner has concrete blockers: `Plan.match/4` rejects an expansion
when any head action remains unknown; `Plan.boundary/4` marks the rest of a path
unstable after any retained operation; and recursive method identities are
normally excluded by the expansion stack. It needs residual structural head
operations, explicit value/mode facts across safe operations, and recursive
region entry/exit edges. Replacing structural matching with ordinary `=` would
be incorrect because `=` can evaluate arithmetic.

No whole-parser target of a few hundred sends is established by this trace.
The testable first target is the 40-send invocation, with equivalent ordered
answers under backtracking and a reduction count that falls along with sends.

## Compiled symbol regions

```sh
ELIXIR_ERL_OPTIONS='+S 1:1' BENCH_SAMPLES=31 mix run --no-start bench/symbol_region.exs
ELIXIR_ERL_OPTIONS='+S 1:1' BENCH_SAMPLES=31 BENCH_COMPARE_REGIONS=true mix run --no-start bench/parse_file.exs
```

`IR.Scan.compile(receiver, selector, branch)` derives a narrow prefix-scan
region from loaded IR. The benchmark supplies only the entry receiver and
selector. The pass checks recursive argument relationships, one-cell
consumption, character exclusions, stop-clause order, conversions, and inherited
classification/rejection paths. No grammar selector names occur in the pass.
`Plan.compile_ir/4` exposes residual IR before register allocation or instruction
selection. Unsupported source shapes retain ordinary dispatch.

The inferred classify/scan/ordered-answer/bind blocks now lower to ordinary JAM
execution. Generic `move`, `get_cons`, `jump`, and `try` instructions provide raw
value-register assignment, list-cell decomposition with a failure edge,
backedges with parallel register transfers, and ordered alternatives preserving
the live registers and store. Existing numeric tests, conversions, unification,
and returns execute the remaining operations. `IR.Code.assemble/1` resolves
block labels. Code is shared across invocations; input lists, output variables,
and scratch registers live in invocation slots.

Entry checks require finite ground Unicode character lists, distinct fresh
outputs, no pending suspensions, and untraced execution. Unsupported cases use
the original relation. The loop and answer conversion count instructions and
survive budget suspension. Each consumed prefix saves an answer continuation;
backtracking returns `point`, `poin`, `poi`, `po`, `p`, with the corresponding
unconsumed input tails. It does not commit to the longest answer.

The source guard includes the root dispatch target, provider ordering and
clauses, helper definitions, and relevant classifier class facts. A caller may
change source after an answer and then fail: saved answer continuations check
guards after invalidation and execute the captured original post-scan calls
when assumptions no longer hold. They preserve changed tail bindings and
ordered duplicate answers. Guard validation is cached within the transaction
using a small plan token; normal resolution-cache invalidation clears it.

The symbol benchmark checks 53 inputs against region-disabled execution for
both first and ordered all-answer results. Its former hand-written scan model
has been removed; its direct execution helper now runs emitted JAM. For timing,
both paths execute the same AL query, conversions, output handling and
transaction bookkeeping. The baseline temporarily replaces only region entry
with fallback in the isolated benchmark process and restores the module
immediately afterward. No production optimization switch or legacy executor is
added. Module-redefinition warnings in comparison runs are expected.

One 31-sample run with one BEAM scheduler measured:

| Query | Regions disabled: reductions / median ms | Regions enabled: reductions / median ms |
|---|---:|---:|
| Symbol, first answer | 78,706 / 1.781 | 35,033 / 0.947 |
| Symbol, all five answers | 116,245 / 2.095 | 38,114 / 0.947 |
| Parse the 172-byte point file | 1,174,967 / 18.208 | 817,703 / 11.982 |

The whole parse uses about 30% fewer reductions in this comparison. These
sequential timing samples do not establish a wall-clock improvement: an earlier
pre-integration run was already 11.46 ms. Timings remain sensitive to host load. These integrated measurements include plan
lookup and source validation, unlike the earlier benchmark-only model's
756/1,933 reduction execution-cost estimates.

Three repeatable instrumented parses recorded 936 sends (previously 1,413),
1,305 ordinary prepared entries (previously 2,006), 16 region entries, and 47
saved region alternatives. Head matches fell from 2,798 to 2,114, prepared
ordinary register slots from 10,554 to 6,746, and fresh ordinary locals from
2,412 to 1,452. The ordinary counters exclude region slots/alternatives, which
are reported separately; this is not evidence that all search has vanished.
The first point-token region contains no internal wrapper sends under valid
guards. This is a specialized source-shape family, not a general optimizer for
arbitrary recursive regions.

## Recursive consumption regions

```sh
ELIXIR_ERL_OPTIONS='+S 1:1' BENCH_JSON=/tmp/consumption.json mix run --no-start bench/parse_region_comparison.exs
```

This compares symbol regions alone (`before`) with symbol plus consumption
regions (`after`). The default eight alternating batches give 160 measured parses per variant.
Both variants are compiled once, with warmup, module loading, collection, and
answer checks outside timing. `BENCH_ROUNDS` and `BENCH_BATCH` control sample counts.
The isolated benchmark replaces the consumption entry clause in memory and
restores the original module afterward. It checks identical complete results.

The compiler recognizes ordered consume/recurse/stop clauses and an optional
one-element entry wrapper from their IR. A pure consumer must have distinct
integer literal cases; duplicate cases and effects reject the region. Current
instruction selection supports literal sets spanning at most 65 integers,
using existing numeric tests. Entry proves the consumed prefix and its stopping
element; it does not traverse the untouched suffix. Open or constrained modes
that lack these proofs retain ordinary execution. Source dependencies guard
cached plans. Saved stop answers preserve longest-first backtracking.

On the point fixture, sends fell from 936 to 687, ordinary prepared entries
from 1,305 to 972, and head matches from 2,114 to 1,108. There are 115 region
entries and 183 saved region alternatives, including the existing symbol
regions. These explicit alternatives still represent necessary prefix answers.

An alternating run measured 821,830 versus 717,942 mean reductions (12.6% fewer).
Median times were 14.187 versus 14.979 ms, with substantial batch variation:
this does not establish a wall-clock speedup. The reduction and send-count
improvements should not be presented as an elapsed-time improvement.

## Direct region outputs

```sh
ELIXIR_ERL_OPTIONS='+S 1:1' BENCH_JSON=/tmp/outputs.json mix run --no-start bench/parse_region_comparison.exs outputs
```

This alternates identical regions with generic output binding (`before`) and
compiler-proven direct output returns (`after`). Both variants keep all region
optimizations enabled. Only benchmark-process code is replaced; the original
module is restored afterward.

Region emission now supplies precompiled return variants that write the rest
value into a region register. A `send_local` destination with a still-fresh
runtime variable can select that variant and the existing register-transfer
return frame. Other outputs retain ordinary unification. Saved alternatives
retain the return frame, so each answer transfers into the appropriate caller
snapshot. Symbol regions specialize both their normal and invalidated-source
suffix exits. This does not eliminate initial local-variable allocation.

Three identical point-fixture binding profiles recorded 1,197 attempted writes
(previously 1,302) and 11,399 occurs/groundness list-cell visits (previously
17,633). Consumption-region visits dropped from 8,008 to 2,258; symbol-region
visits from 1,545 to 1,061. Ordinary equality visits remained 6,431.

Thirty alternating samples per variant measured 716,437 versus 690,201 mean
reductions (3.7% fewer). Median time was 14.078 versus 16.216 ms: this run does
not demonstrate a wall-clock improvement, despite eliminating the targeted work.

### Investigating the output-return timing regression

```sh
ELIXIR_ERL_OPTIONS='+S 1:1' BENCH_ROUNDS=100 BENCH_BATCH=1 BENCH_JSON=/tmp/output-pairs.json mix run --no-start bench/parse_region_comparison.exs outputs-interleaved
```

This loads one benchmark-only module with a process-local switch and alternates
individual parses in AB/BA order. Both paths pay for the switch. There is no
per-pair module loading or compilation, and both paths are warmed first.
Results report paired round changes as well as marginal medians. For batches
larger than one, each pair compares the two within-round median times.

Two independent 100-pair runs found median paired changes of -0.734 ms (-4.5%)
and -0.272 ms (-2.0%), with direct outputs faster in 64 and 56 pairs respectively.
The earlier 15% marginal-median regression was not stable under these controls.
The first run illustrates why pairing matters: its separate overall medians
were 18.242 and 18.726 ms, even though the median within-pair change favored
direct outputs. The repeat's separate medians were 19.600 and 18.869 ms.

Mean VM CPU time favored different variants between runs (20.0/20.7 ms, then
20.55/19.87 ms); it includes other VM processes and has millisecond resolution.
Observed end-of-parse heap sizes and minor-GC counters did not increase with
direct outputs. End heap size is not allocated words, and the minor-GC counter
can reset on major GC, so these are diagnostic indicators only.

Set `BENCH_FUNCTION_PROFILE=/tmp/output-functions` with this mode to collect
separate 20-parse `eprof` reports after timing. Selection/transfer functions had
small exclusive costs in that profile, with 79 extra map-enumeration protocol
calls per parse. Shared helper costs cannot be completely attributed from this
flat profile. Binding writes and occurs-check traversal still fall as reported
above. Evidence supports a modest benefit, not a large speedup or a proven
15% CPU regression. No runtime changes were made during this investigation.

## Lookup, invalidation, and GC investigation

```sh
ELIXIR_ERL_OPTIONS='+S 1:1' BENCH_JSON=/tmp/lookups.json mix run --no-start bench/parse_lookup_profile.exs
ELIXIR_ERL_OPTIONS='+S 1:1' BENCH_JSON=/tmp/lookup-cost.json mix run --no-start bench/parse_lookup_comparison.exs
ELIXIR_ERL_OPTIONS='+S 1:1' BENCH_JSON=/tmp/heap-cost.json mix run --no-start bench/parse_memory_comparison.exs
ELIXIR_ERL_OPTIONS='+S 1:1' BENCH_JSON=/tmp/combined.json mix run --no-start bench/parse_lookup_comparison.exs memory
ELIXIR_ERL_OPTIONS='+S 1:1' BENCH_JSON=/tmp/gc.json mix run --no-start bench/parse_gc_profile.exs
```

All run in isolated stores and verify the complete parse result. Lookup counts
must agree across three warm samples. The comparison modes deliberately bypass
invalidation or validation inside benchmark-only modules to estimate the cost
of these operations on this fixed, non-mutating parser workload. They are not
safe general-purpose cache implementations. The heap probes change only the
benchmark process's heap floor, restore it afterward, and exclude heap setup and
forced pre-sample GC from parse timing. This measures steady-state execution,
not worker startup cost or concurrent memory demand.

The lookup profile found 606 method scans across 604 distinct keys: 432 during
execution and 174 during plan validation. There were 47 plan-validation calls
covering 33 distinct plans, plus one loop validation. End-of-query transaction
recording calls `AL.Object.set_class` for the new transaction object, which
invalidates provider caches across the entire branch. Consequently the next
warm parse rebuilds provider lists, even though the parser's classes and methods
have not changed. A transaction-local validity token alone would not fix this.

Preserving provider caches only during transaction recording reduced mean
reductions from 695,180 to 591,769 (14.9%). Bypassing plan validity checks alone
reached 661,033 (4.9%); both reached 576,032 (17.1%). These savings overlap.
Provider preservation needs precise receiver/dependency invalidation in a real
implementation; it must not become a special exemption for transaction objects.

A disjoint grouping of exclusive function times from the 20-parse `eprof` run:

| Function group | Instrumented function time |
|---|---:|
| Lookup, storage, cache, dispatch | 23.1% |
| Binding and unification | 22.2% |
| VM, operands, heads, tracing | 23.3% |
| Planning and compilation | 2.9% |
| Shared collection/runtime helpers | 22.6% |
| Other | 5.8% |

This is function attribution, not an exclusive wall-time budget. Shared helper
work is intentionally not reassigned to callers. Allocation is distributed
through these functions; GC is measured separately and must not be added to
this table's percentages. GC tracing observed roughly 29–40% of elapsed time
inside collection intervals across diagnostic runs. Trace overhead and retaining
trace records alter heap behaviour, so the exact percentage and collection
count are not stable. The reusable GC probe keeps event details in a separate
collector process. Untraced heap-size comparisons provide stronger causal
support than the traced percentages.

Instrumented reads returned approximately 269,848 flat term words per parse,
including 134,783 from compiled-method caches and 45,964 from compiled-plan
caches. This is a returned-term size proxy, not measured allocation: it does not
account for sharing or copies inside Mnesia. It motivates inspecting compiled
code/metadata representation and cache-read copying alongside temporary terms.

An untraced, rotating 60-round heap comparison measured 12.489 ms with the
default floor versus 7.824 ms with a one-million-word floor. Mean observed end
heap sizes were 559,914 versus 1,199,872 words (about 4.5 versus 9.6 MB on this
64-bit runtime). A two-million-word floor used 2,073,148 words without a material
additional speed improvement.

The combined 60-round experiment measured:

| Variant | Median ms | Mean reductions | Median paired time change |
|---|---:|---:|---:|
| Normal | 14.846 | 693,313 | — |
| Preserve providers at transaction recording | 11.904 | 595,446 | -17.8% |
| One-million-word heap floor | 9.102 | 639,288 | -38.2% |
| Both | 6.686 | 556,312 | -53.4% |

A second independent 60-round run measured 14.830 ms normally and 6.645 ms
with both changes, with a median paired time reduction of 50.6%. This supports
a twofold opportunity on the point fixture under diagnostic conditions, not a
production speedup. No runtime policy or invalidation changes
were made as part of the investigation.

## Allocation changes after the lookup investigation

Provider cache rows now group selectors by receiver. A grounded receiver's
class change deletes that receiver's group by key; wildcard class changes,
method edits, and hierarchy changes retain broad invalidation. Transaction
recording therefore preserves unrelated provider entries without a transaction
exemption. The lookup probe now observes zero method scans per warm parse,
down from 606. The historical `preserve` modes in `parse_lookup_comparison.exs`
no longer bypass the normal transaction-recording path; their earlier results
above describe the implementation before this change.

Rejection selection tables now contain integer clause masks instead of copies
of complete compiled clauses. Selection preserves source order and each
clause's specialized head/body. Masks support more than one machine word and
preserve duplicate answers. Open inputs retain the complete clause sequence.

Three repeatable lookup-profile samples measured:

| Compiled-method component | Before masks, words | After masks, words |
|---|---:|---:|
| Canonical clauses | 48,147 | 48,147 |
| Index, including rejections | 86,213 | 17,990 |
| Rejections alone | 68,583 | 360 |
| Whole returned compiled-method terms | 134,783 | 66,560 |

This removes 50.6% of the flat term words returned from compiled-method caches.
It is a representation/copying proxy, not a measurement of total allocation.
The mask selection walk itself constructs a candidate list at execution time.
Heap policy is unchanged.

A 60-sample default-heap parse run after both changes measured a 13.062 ms
median and 595,530 mean reductions, with complete AST equivalence to
`AL.Syntax`. This is a current observation, not a paired speedup claim against
the earlier measurements. The full isolated suite passed 917 tests.

A separate 40-parse GC trace still attributed 35.6% of elapsed time to GC
intervals (34.95 minor and 2.9 major collections per parse on average).
Tracing changes execution cost; this confirms substantial remaining GC work,
without establishing a causal improvement over the historical trace.

## Resident compiled code

Compiled methods and plans now have transactional version tokens in a separate
cache table. Evaluator processes retain up to 256 code entries across queries.
A matching token reuses the existing term; a changed token loads the new body.
Method edits invalidate the token in the same transaction as the body. Plan
dependencies are still checked on every access. Aborted replacements cannot
become visible through process retention because their tokens are rolled back.

This avoids repeatedly copying warm code from Mnesia into a long-lived evaluator.
It does not share heap terms between evaluator processes. A new process still
loads its working set; retained entries trade bounded entry count (not a byte
limit) for fewer subsequent copies. Heap settings remain unchanged.

```sh
ELIXIR_ERL_OPTIONS='+S 1:1' mix run --no-start bench/parse_code_comparison.exs
```

The benchmark restores the previous method/plan lookup functions inside an
in-memory diagnostic module, alternates individual parses in AB/BA order,
checks complete answers, and restores the original module afterward. Both
variants run in the same process with its resident working set present. Forced
pre-sample GC is excluded from timing. This isolates copying versus reuse for
a warm evaluator; it does not measure fresh-process startup or concurrent
workers' aggregate memory usage.

The lookup probe's three identical warm samples read no compiled method or
plan bodies. The preceding 66,560 + 45,964 flat words of body reads were
replaced by 2,327 words of version-token reads. Plan/loop validation counts
remained 47 and 1. These are returned-term sizes, not total allocation.

Two independent 100-pair runs at default heap settings measured:

| Run | Previous lookup median ms | Resident median ms | Median paired change | Resident wins |
|---|---:|---:|---:|---:|
| 1 | 10.300 | 8.239 | -20.1% | 91/100 |
| 2 | 9.671 | 8.110 | -19.6% | 93/100 |

Mean reductions were approximately 574–575k before and 576k after. The
wall-time improvement comes without a reduction-count improvement. The full
isolated suite passed 921 tests, including cross-process invalidation,
transaction rollback, plan replacement, and branch isolation.

The unmodified runtime's 60-sample `parse_file.exs` run measured 8.646 ms
median and 574,592 mean reductions, with complete AST equivalence to
`AL.Syntax`. Use the paired results above to attribute the improvement.

## Temporary register initialization

The compiler now omits fresh logical-variable initialization when a local's
first use is an eligible register write. Earlier reads, nested control-flow
uses, tracing, and `forall` remain conservative. Local equality materializes a
variable on demand for wildcard or unresolved-arithmetic cases. Scan-region
scratch registers start empty; relational conversion and suffix outputs still
receive variables.

The binding probe observed 2,065 → 1,833 fresh-variable creations per point
parse, a reduction of 232 (11.2%). Of these, 208 were scan scratch initializers
and 24 were clause locals (1,278 → 1,254). Binding writes stayed at 1,197.
This removes setup allocations; it does not yet eliminate binding-map updates.

```sh
ELIXIR_ERL_OPTIONS='+S 1:1' mix run --no-start bench/parse_local_comparison.exs
```

The benchmark compiles both initializer lists into diagnostic metadata and
alternates which list each invocation uses, including callable and scan-region
entry. Both modes execute the same optimized instructions and use unchanged
heap settings. Its control restores eliminated variable initializers, not the
old scan initializer's intermediate list construction. It restores loaded
modules afterward and verifies complete parse answers.

A 100-pair run measured 8.6245 ms with initializers versus 8.6230 ms with them
elided, with 50/100 wins and a median paired change of +0.10%. Mean reductions
were 577,780 versus 576,062. There is no demonstrated wall-time improvement.
The remaining binding profile attributes 248 writes to primitives and 566 to
head matching, making direct primitive outputs a more promising follow-up than
further initializer-only changes.
The full isolated suite passed 925 tests, including earlier variable reads,
wildcard assignment, aliasing, alternatives, and unresolved arithmetic.

## Direct primitive outputs

String/code, atom/string, and map/pair conversions can now write a result
directly to a register proven fresh by the existing register analysis. The
destination remains initialized as a logical variable for fallback modes.
Open inputs and unsupported shapes use ordinary relational execution; if the
call suspends, its continuation retains the ordinary primitive instruction so
later aliases and constraints cannot be bypassed by a direct register write.

The binding probe measured 1,197 → 1,126 writes per point parse: 71 fewer
overall, with primitive-attributed writes falling from 248 to 177. Both
directions, Unicode, invalid codepoints, duplicate keys, shared map values,
suspension aliases, constrained outputs, and ordered answers are exercised by
the semantic tests.

```sh
ELIXIR_ERL_OPTIONS='+S 1:1' mix run --no-start bench/parse_primitive_comparison.exs
```

This alternates direct-output execution with ordinary primitive unification
inside the same loaded module, using the same compiled code and unchanged heap
settings. A 100-pair run measured 8.5565 ms generic versus 8.5940 ms direct,
51/100 direct wins, and a median paired change of -0.12%. Mean reductions were
574,419 versus 574,969. There is no demonstrated wall-time improvement despite
the lower binding-write count; these counts are not allocated-word totals.
The full isolated suite passed 930 tests.

## Heap allocation by function

```sh
ELIXIR_ERL_OPTIONS='+S 1:1' BENCH_JSON=/tmp/parse-allocation.json \
  mix run --no-start bench/parse_allocation_profile.exs
ELIXIR_ERL_OPTIONS='+S 1:1' BENCH_JSON=/tmp/parse-allocation-callers.json \
  mix run --no-start bench/parse_allocation_profile.exs callers
```

This uses OTP `tprof` in `call_memory` mode, with all functions traced in a
dedicated evaluator worker. Twenty warm parses precede three measured batches
of twenty parses. A separate process controls tracing; result validation occurs
with tracing disabled. Startup, code warmup, profiler control, and validation
are excluded. Each measured call includes normal `AL.eval` transaction work.
Heap policy is unchanged. These are allocated heap words, not live heap size,
off-heap binary payloads, other processes' allocations, or elapsed-time shares.
No runtime code is rewritten. Instrumented timings must not be used as a
performance comparison.

On OTP 28 with eight-byte words, the point fixture allocated 568,180, 566,163,
and 562,566 words per parse across the three batches: **4.50–4.55 MB**, averaging
565,636 words / 4.53 MB per parse. Leading exclusive function measurements:

| Function | Mean words/parse | Share |
|---|---:|---:|
| `AL.JAM.step/12` | 71,669 | 12.7% |
| `:erlang.setelement/3` | 69,759 | 12.3% |
| `AL.Var.bind_resolved/4` | 39,267 | 6.9% |
| `Map.update/4` | 24,647 | 4.4% |
| `:ets.lookup/2` | 22,457 | 4.0% |
| `AL.Var.fresh/2` | 7,332 | 1.3% |

The `callers` mode leaves `setelement/3` and `Map.update/4` untraced so their
allocations accrue to the next traced caller. Its totals remained comparable
(559,184–569,143 words/parse). This is an alternate attribution of the same
work, not an additional allocation budget. Head matching gained 25,211 words,
the clause-local register initialization reducer 11,528, a step transfer
reducer 9,350, and `step/12` itself 6,940. `AL.Var.mark_ground/2` gained about
13,106 words from map updates, so the `Map.update/4` bucket must not all be
attributed to caches.

The allocation evidence favors inspecting tuple reconstruction during head
matching, register setup, and VM frame/continuation execution. Fresh-variable
objects themselves account for only 1.3%; fewer variable creations alone were
never a large enough allocation-volume target for a twofold speedup.

## Remaining send-chain investigation

Rerun `parse_boundary_profile.exs` to include `symbol_runs` and
`scan_admission` in its JSON. The point fixture still performs 687 sends;
three warm samples agree exactly and preserve the complete parse answer.
`symbol_runs` partitions contiguous trace runs beginning with a `symbol` send
from outside its scan/classification helper family and ending at the next send
from outside that family. Runs are checked for overlap. This is source-reviewed
send-path accounting, not a CPU profile or an instrumented call tree.

| Path | Invocations | Sends |
|---|---:|---:|
| Uppercase variables (`Self`, `Sum`, `X`, `Y`) | 13 | 278 |
| Constrained selectors (`get` three times, `=`, `+`) | 5 | 144 |
| Already single-send symbol attempts | 16 | 16 |
| End-of-input symbol attempt | 1 | 5 |
| Everything outside these runs | — | 244 |

The two expensive families account for 422/687 sends (61.4%). A `Self` token
uses 26 sends, including numeric recognition that fails, its character scan,
and `variable_name -> within -> sequence -> match_pattern -> concat ->
zero_or_more(code)` over its converted character list. Numeric-name rejection
then goes through `unless -> match_pattern -> concat -> integer_name`.

The admission probe confirms two distinct gaps. All 13 uppercase inputs have
fresh outputs, but the existing scan plan's prefix rejection sends them to
generic execution. The five selector inputs have constrained outputs and fail
the region's fresh-output admission condition before prefix classification.
The current region therefore covers the simple atom-result mode but misses
variable construction and constrained result checking.

A concrete next experiment is to extend the source-derived region plan with
explicit classification/result alternatives and guarded result unification.
The original scan can establish the character facts now rediscovered through
conversion and `within`; result construction can retain the original provider
order and `(var Name)` versus atom distinctions. Prefix answers, aliases,
constraints, open/generation modes, and mutation invalidation must remain valid.
These facts must be inferred from method IR, not grammar names embedded in JAM.

If each of these 18 invocations could run as one send boundary, the idealized
count would be 283 sends rather than 687. This is a count opportunity, not a
speed prediction: scanning, conversion, construction, and genuine alternative
answers still have to execute. No twofold wall-time improvement has been
demonstrated by this investigation, and no runtime optimization was added.

## Constrained scan results

```sh
ELIXIR_ERL_OPTIONS='+S 1:1' BENCH_JSON=/tmp/scan-comparison.json mix run --no-start bench/parse_scan_comparison.exs
```

The scan region now admits bound atoms and constrained output variables,
using the existing result unification. Rest must still be fresh and distinct
from the output. Open inputs and unsupported result shapes retain generic
execution. No grammar-specific instruction was added.

The comparison alternates fresh-only and extended admission in one loaded
module, warms both modes, and checks every complete parse answer. Across 100
pairs, the final guard measured 8.4255 ms versus 7.649 ms median, winning 92
pairs with a median paired improvement of 10.07%. Mean reductions fell from
574,927 to 468,959 (18.4%). Heap size was effectively unchanged; this is not
an allocated-byte measurement. An earlier run measured 8.1905 versus 7.4315 ms.

Boundary profiling reports 548 sends instead of 687 and 174 resumed
alternatives instead of 210. Three warm samples agree. The five constrained
selector paths now use five sends instead of 144. The 13 uppercase-variable
paths remain generic.

An uppercase-result prototype preserved ordinary prefix answers but did not
preserve all pending provider alternatives under mutation, so it was removed.
After the first constructed variable answer, changing its classifier to fail
can activate the later raw-atom alternative for every prefix. Guarding only
the saved answer suffix cannot reproduce that behavior. A regression test
checks these answers against traced execution. Supporting this mode requires
retaining those pending provider continuations as part of the region design.

## Successor call comparison

```sh
mix run bench/succ.exs 10000
```

This compares a recursive send with a loop carrying a resolved method ID into
`vm_oapply`. Both use the same compiled clause matcher. Send targets are cached,
so the send loop does not walk inheritance on every iteration. The direct loop
has an extra method-ID argument, and resolves that ID once at entry. Each
iteration uses a fresh branch; branch creation and disposal are outside the
Benchee timing interval. This is a comparison of the two complete loops, not
a pure measurement of inheritance lookup cost.
