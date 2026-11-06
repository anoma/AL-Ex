# Language benchmarks

Run from the repository root:

```sh
mix run --no-start bench/parse_file.exs
mix run --no-start bench/parsing.exs
mix run --no-start bench/bnf.exs
```

| Benchmark | Work measured | Correctness check |
|---|---|---|
| Parse file with AL.Syntax | Tokenize and parse `fixtures/point.al` using the native source reader | Full parsed result remains identical |
| Parse file with AL grammar | Execute `parse al_grammar (program Items) Source` through AL, including transaction overhead | AST matches the native reader after normalizing variable representation and method reconsult directives |
| Binary grammar scaling | Parse short/long symbols, parse and generate Unicode string literals, and parse 1/4/16 class definitions | Exact strings and symbols; program ASTs checked against the native reader |
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

## Binary sequence grammars

```sh
ELIXIR_ERL_OPTIONS='+S 1:1 +t 4000000' BENCH_JSON=/tmp/parsing.json mix run --no-start bench/parsing.exs
```

Strings match ordinary head/tail patterns. For example, `[Char . Rest]`
matches `"λhello"` with `Char = "λ"` and `Rest = "hello"`. Matching decodes one
UTF-8 codepoint and keeps the remainder binary. Empty strings match `[]`.
Open character patterns become binaries when their tails resolve to binaries;
ordinary proper lists retain their representation.

DCG character and literal patterns compile to ordinary unification. Character
classifiers use binary literals. Text capture and generation use recursive
relations with a binary empty tail; literal prefixes attach directly to open tails.
There is no grammar scan compiler, executor, or guarded-region continuation.

`bench/parsing.exs` checks parsing and generation, Unicode and escapes, whitespace,
and increasing source sizes. `bench/consumption.exs` checks first and all answers
for recursive sequence consumption. Both use isolated stores and verify outputs.

### Initial sequence correction measurements

Two runs of each version, in alternating order, used one BEAM scheduler, three
warmups and 15 checked samples per workload. The table gives the range of the
two run medians in milliseconds. The original version is the saved parser from
before the binary migration, including its original optimizations.

| Workload | Original character lists | Binary sequences |
|---|---:|---:|
| Parse 16 definitions | 58.75–62.41 | 84.58–88.23 |
| Parse 128-character symbol | 1.14–1.20 | 0.88–1.16 |
| Generate 128-character symbol | 1.10–1.12 | 1.04–1.10 |
| Parse quoted Unicode, 256 characters | 3.20–3.67 | 3.08–5.45 |
| Format 1,024 literal characters | 8.34–8.34 | 7.62–8.70 |

The 16-definition parse used approximately 11.27 million reductions versus
11.40 million originally. Its elapsed-time regression remains; fewer reductions
do not establish that binary matching makes the whole parser faster.

The removed binary scan implementation used about 7.47 million reductions for
16 definitions and 14,545 for the long symbol, versus 11.27 million and 122,714
with ordinary sequence matching. Removing it sacrifices those specialized
shortcuts. No equivalent recognizer or scan executor replaces it.

Partial string construction also exposed duplicate suspension subscriptions.
A waking execution now removes its other subscriptions. Binary substitution
assembles resolved character chains once, using binary fragments internally,
while keeping ordinary proper lists as lists.

## Printing, formatting, and string-operation comparison

These measurements describe the incomplete literal-generation path. The
completed correction and its measurements are recorded below.

```sh
ERL_FLAGS='+S 1:1 +SDcpu 1 +SDio 1' BENCH_SAMPLES=21 \
  BENCH_JSON=/tmp/text-operations.json mix run --no-start bench/text_operations.exs
```

The same harness ran against the saved original character-list implementation
and the current binary sequence implementation, in current/original/original/current
order. Each run used an isolated store, one BEAM scheduler, warmup calls, and
21 checked samples per workload. Inputs and query parsing were outside timing;
AL workloads include transaction overhead. Printing measures text production,
not terminal I/O. Printed terms were parsed back and checked for equivalence;
all 17 output hashes also matched across all four runs.

Ranges below are the two run medians, in milliseconds. These comparisons cover
the binary migration and subsequent correction together, not just the final
removal of the scan machinery.

| Workload | Original character lists, ms | Current binary sequences, ms |
|---|---:|---:|
| format short mixed template | 0.828–0.847 | 2.250–2.423 |
| format 3584-byte argument | 0.720–0.724 | 0.534–0.553 |
| format six nested wrappers | 1.588–1.615 | 1.219–1.222 |
| format 16 large arguments | 2.128–4.046 | 1.122–1.136 |
| format 1024 literal codepoints | 7.000–7.137 | 8.726–8.911 |
| print quoted Unicode 256 codepoints | 4.514–4.712 | 2.411–2.419 |
| print quoted escapes 256 codepoints | 5.578–5.640 | 2.471–2.474 |
| print list of 64 integers | 16.992–17.987 | 1,194.754–1,259.971 |
| print list of eight maps | 25.669–29.290 | 148.750–156.820 |
| concat two 3584-byte strings | 325.944–341.940 | 0.087–0.215 |
| length 1536 codepoints | 4.009–4.869 | 0.094–0.298 |
| split 16 Unicode fields | 10.190–13.960 | 4.556–5.533 |
| join 16 fields through split | 2.662–5.901 | 1.184–1.449 |
| map 100 integer pairs | 1.842–2.087 | 1.064–1.072 |
| fibonacci forward 12 | 2.047–5.666 | 2.223–2.256 |
| fibonacci backward 144 | 10.152–10.570 | 7.610–7.868 |
| native printer eight maps | 0.067–0.072 | 0.027–0.028 |

The strongest gains are in concatenation, codepoint counting, quoted-string
output, and insertion of existing strings into format templates. Integer and
structured-term printing have substantial regressions. Printing integers 1–64
increases from about 2.60 million to 109.35 million reductions, a 42-fold
increase in work, and takes roughly 70 times longer.

Smaller wall-time changes need caution. The native printer source and its 3,989
reductions are identical in both versions, yet its timings differ. Forward
Fibonacci also has noisy timings and approximately unchanged work; backward
Fibonacci uses 1.19 million reductions in both versions. List mapping increases
from 79,153 to 169,736 reductions despite its lower observed elapsed time.
Those control results do not establish general VM speedups.

### Printing diagnosis

Separate checked probes used 11 warm samples per version:

| Workload | Original, ms | Current, ms |
|---|---:|---:|
| print integer 7 | 0.531 | 0.919 |
| print integer 42 | 0.936 | 1.949 |
| print integer 64 | 0.675 | 2.711 |
| print integer 128 | 1.067 | 2.067 |
| print 64 copies of integer 1 | 6.465 | 37.719 |
| print 64 copies of atom a | 15.973 | 47.823 |
| print integer list 1..8 | 1.408 | 10.490 |
| print integer list 1..16 | 3.656 | 22.880 |
| print integer list 1..32 | 9.136 | 127.380 |
| format short all-string template | 1.670 | 1.940 |

A separate `eprof` run of printing integers 1–32 identified 3,442 calls that
suspend binary text operations. The machine checked pending goals 15,154 times,
visiting 1,214,116 suspension entries. The original profile had no suspension
calls for this workload. These are instrumented call counts, not timings to
compare with the uninstrumented medians.

The grammar's `char` pattern uses ordinary head/tail unification, but literal
terminals still compile to `vm_text_concat`. During generation, a known literal
prefix with an unknown output tail suspends. Accumulated pending goals are
polled by the instruction loop. The original list representation could attach
characters directly to an open tail. The digit relation also changed from an
arithmetic constraint to ten concrete alternatives, adding search during number
generation. These remaining paths are a documented regression; this benchmark
pass makes no runtime changes.

## Completed binary generation

Literal grammar terminals now translate to ordinary head/tail unification when
the rule is defined. Both static terminals and dynamic literal patterns can
attach to open tails. Quoted-string generation uses the same recursive character
relation as parsing; the separate `escaped_fragments` assembly path is removed.
Known integers derive their digits with remainder and integer division. Open
numbers retain the accumulating relation, constraints, and digit overrides.

The existing clause rejection check also recognizes a known first character in
an ordinary sequence-unification pattern. It remains conservative for open and
list inputs. This replaces the filtering lost when terminal bodies stopped
using `vm_text_concat`; it adds no instruction or grammar scanner.

For printing integers 1–32, the post-correction profile records no suspension
creation or readiness checks, versus 3,442 suspensions and 1,214,116 pending-entry
checks before the fix. The full isolated suite finishes with 1,297 tests and the
same two pre-existing diagnostic failures:
`unmatched_clause_body_names_the_actual_call` and
`native_failed_unification_preserves_constraint_diagnostics`.

### Repeated comparison against the original character-list implementation

The same checked harness ran in original/corrected/corrected/original order,
using private stores, one scheduler, and 21 timed samples per workload. These
ranges are the two run medians in milliseconds. Every output hash matches across
all four runs. The reductions column is corrected work divided by original work;
below 1 means fewer BEAM reductions. Neither reductions nor wall time alone is
a complete allocation or CPU-cost measurement.

| Workload | Original, ms | Corrected, ms | Reductions ratio |
|---|---:|---:|---:|
| format short mixed template | 0.827–0.848 | 0.871–1.200 | 0.88× |
| format 3584-byte argument | 0.759–0.860 | 0.528–0.840 | 0.68× |
| format six nested wrappers | 1.644–1.728 | 1.246–1.291 | 0.47× |
| format 16 large arguments | 2.187–2.189 | 1.118–1.189 | 0.22× |
| format 1024 literal codepoints | 7.090–7.228 | 8.281–8.992 | 0.40× |
| print quoted Unicode 256 codepoints | 4.453–4.599 | 1.538–1.571 | 0.28× |
| print quoted escapes 256 codepoints | 4.987–6.028 | 1.733–1.744 | 0.29× |
| print list of 64 integers | 18.063–22.524 | 7.497–12.210 | 0.33× |
| print list of eight maps | 41.532–42.553 | 15.208–24.308 | 0.95× |
| concat two 3584-byte strings | 341.721–348.707 | 0.142–0.309 | 0.00× |
| length 1536 codepoints | 4.168–10.356 | 0.210–0.331 | 0.01× |
| split 16 Unicode fields | 7.291–14.065 | 1.542–3.102 | 0.32× |
| join 16 fields through split | 5.494–8.913 | 3.489–4.669 | 0.36× |
| map 100 integer pairs | 1.258–2.526 | 0.774–1.329 | 2.12× |
| fibonacci forward 12 | 7.224–7.676 | 3.660–7.777 | 1.04× |
| fibonacci backward 144 | 10.569–10.595 | 10.048–10.281 | 1.00× |
| native printer eight maps | 0.068–0.068 | 0.045–0.081 | 1.00× |

The severe printing regression is removed. Integer-list printing now uses about
857,000 reductions versus 2.60 million originally and 109.35 million in the
incomplete correction. Quoted-string printing uses about 71–72% fewer reductions.
The mixed-map printer's work changes much less; its elapsed-time improvement
should not be generalized into a uniform VM speedup. Native-printer timings vary
despite identical code and work. List mapping still does about twice the original
work, an outstanding result from the wider migration.

The parser cross-check used two runs per version with 15 checked samples:

| Workload | Original, ms | Corrected, ms |
|---|---:|---:|
| 16 definitions | 60.679–62.755 | 89.339–93.225 |
| parse symbol128 | 2.960–2.972 | 1.788–2.286 |
| generate symbol128 | 1.179–2.412 | 1.096–1.806 |
| parse quoted256 | 3.104–4.684 | 2.823–3.145 |
| format literal1024 | 7.323–8.966 | 7.429–8.092 |

The 16-definition parse still regresses: approximately 11.83 million reductions
versus 11.39 million originally, and 89–93 ms versus 61–63 ms. Literal-heavy
formatting also has no demonstrated speedup. Those limits remain visible; the
printing gains do not establish that the entire binary migration is faster.

## Parser regression attribution after binary generation

The original character-list baseline includes `AL.JAM.Scan`. Disabling only
its runtime entry, while retaining ordinary loop optimization, changes the
16-definition result substantially. Two runs in reversed order, with 15 checked
samples per run, measured:

| Implementation | Median ranges, ms | Mean reductions, approximately |
|---|---:|---:|
| Original, including scan optimization | 54.6–61.0 | 11.39 million |
| Original, scan entry disabled | 147.9–155.3 | 48.75 million |
| Binary correction before this follow-up | 89.0–101.5 | 11.83 million |

This separates the removed optimizer's contribution from the migration as a
whole. It does not isolate binary representation from every grammar change.
The binary implementation is substantially cheaper than the original ordinary
execution path, but still slower than the original optimized path.

A separate allocation profile of the same input measured about 44.4 MB of heap
allocation per original optimized parse and 96.3 MB per binary parse. These are
allocated heap words converted to bytes, not peak live memory or total binary
storage. Prepared frames rise from 8,019 to 26,450; with the old scan entry
disabled the original prepares 20,219. A separate GC-traced run measured mean
collection intervals of 11.1 ms originally and 18.4 ms after migration. GC
explains part of the elapsed-time gap, not all of it.

Function profiling records fewer substitution-walk calls after migration
(98,363 to 74,767), while clause-head matching rises from 44,562 to 122,323.
The main evidence points to additional ordinary calls, alternatives and bindings;
it does not identify repeated binary materialization as the main bottleneck.
Profiling overhead means function timings are not subdivisions of normal runtime.

A temporary full-literal-prefix rejection experiment reduced parser reductions
by only about 0.1%, with no convincing timing benefit. It was not retained.

The retained runtime change extends the existing direct numeric disequality
comparison to two binary values. Previously, character exclusions and binary
progress checks entered general unification despite having fully known operands.
Mixed binary/list comparisons and open variables still use relational unification.
No instruction, primitive, scanner, or grammar rule was added.

A separate changed/control/control/changed comparison, again with 15 checked
samples per workload and fresh isolated stores, measured:

| Workload | Control reductions | Binary comparison reductions | Change |
|---|---:|---:|---:|
| 16 definitions | 11.82 million | 11.30 million | −4.4% |
| Parse symbol128 | 122,715 | 102,128 | −16.8% |
| Generate symbol128 | 96,232 | 78,847 | −18.1% |
| Parse quoted256 | 348,725 | 329,443 | −5.5% |
| Format literal1024 | 857,877 | 810,936 | −5.5% |

Full-parser median times were 87.9–91.6 ms for control and 91.1–93.1 ms with the
change: no demonstrated whole-parser speedup. Symbol parsing measured 2.22–2.81 ms
versus 0.816–0.845 ms, but elapsed times elsewhere were noisy. The consistent
claim is reduced work, not a general timing improvement. All benchmark answers
matched their expected values. The retained implementation passes 57 focused
sequence, grammar, text, rejection, and constraint tests, including tracing,
deferred disequality and binary/list equivalence.

Raw measurements and temporary profiling/experiment scripts are in
`/tmp/al-parser-correction/`. The checked workloads are also represented in
`bench/parsing.exs`; `bench/parse_allocation_profile.exs` and
`bench/parse_gc_profile.exs` provide the underlying profiling methods.



## Binary scan optimization restoration

The restored optimizer recognizes deterministic longest-first character
consumption and text accumulation from loaded AL definitions. Character rules
use binary head/tail patterns, binary disequalities and finite character domains.
Execution consumes UTF-8 with BEAM binary matching and keeps binary remainders.
It adds no AL primitive or JAM instruction and changes no bootstrap grammar.

The generated alternatives use ordinary `get_cons`, `try`, `jump`, equality and
return handling. `Machine` accepts a prepared compiled clause and enters it
through `Frame.returning_entry`. There is no guarded-region descriptor, special
resume dispatch, or separate output-transfer helper. The two restored modules
contain 519 lines, plus the small optimizer/entry integration.

Only completed, deterministic longest-first searches qualify. Their shorter
prefix choices were already established by consuming the input. Generation,
bound/constrained text outputs, pending suspensions, tracing, effects, duplicate
classifier alternatives, dynamic recursive selectors and unsupported rule shapes
retain ordinary execution. Cache dependencies include the root, recursive method
and classifier/provider definitions. Source-edit tests cover invalidation and
choices already established before an edit. Shortest-first and escape-processing
relations are not replaced by eager scanning.

This is a partial restoration: the original character-list optimizer also fused
surrounding symbol-recognition provider logic and inferred rejection tests. Those
parts have not been restored here. The timing comparison therefore still includes
a difference in optimization coverage, not only string representation.

### Verification and timings

An initial optimizer-on/off/off/on comparison used 21 checked samples per
workload, fresh stores and one scheduler. Full parsing measured 65.5–69.4 ms with
the optimizer versus 98.4–102.7 ms without it. Two reruns of the original optimized
character-list implementation measured 59.3–62.8 ms.

The broad text suite exposed unnecessary eligibility checks for unrelated string
methods: splitting used about 8% more reductions. Restricting candidate shapes
removed that penalty. A final on/off/on comparison, again with 21 samples, gave:

| Workload | Disabled median, ms | Restored medians, ms | Reduction change |
|---|---:|---:|---:|
| 16 definitions | 90.133 | 63.936–66.560 | -28.1% |
| parse symbol128 | 0.802 | 0.293–0.935 | -87.6% |
| generate symbol128 | 1.048 | 1.051–1.055 | -0.2% |
| parse quoted256 | 3.077 | 3.291–3.527 | +1.5% |
| format literal1024 | 7.871 | 0.454–1.198 | -96.5% |

The final full parse uses about 8.12 million reductions versus 11.30 million
without the optimizer. The original optimized version uses about 11.40 million,
but remains slightly faster in elapsed time. This does not establish that the
binary migration has met its performance target.

The separate text/printing suite measured:

| Workload | Disabled median, ms | Restored medians, ms | Reduction change |
|---|---:|---:|---:|
| format short mixed template | 0.852 | 1.171–1.229 | -12.3% |
| format 3584-byte argument | 0.794 | 0.447–0.692 | -37.1% |
| format six nested wrappers | 1.282 | 1.088–1.101 | -32.5% |
| format 16 large arguments | 1.133 | 1.120–1.123 | -16.3% |
| format 1024 literal codepoints | 8.819 | 0.438–0.449 | -96.6% |
| print quoted Unicode 256 codepoints | 1.597 | 1.508–2.563 | +0.1% |
| print quoted escapes 256 codepoints | 1.762 | 1.736–1.772 | +0.4% |
| print list of 64 integers | 8.966 | 6.946–17.850 | +0.2% |
| print list of eight maps | 12.388 | 15.961–29.600 | +1.4% |
| concat two 3584-byte strings | 0.135 | 0.499–0.648 | +0.2% |
| length 1536 codepoints | 0.354 | 0.307–0.547 | +0.1% |
| split 16 Unicode fields | 2.172 | 2.135–3.227 | +0.1% |
| join 16 fields through split | 5.666 | 4.235–5.612 | +0.3% |
| map 100 integer pairs | 1.538 | 1.041–1.764 | +0.6% |
| fibonacci forward 12 | 7.299 | 4.371–6.799 | +0.4% |
| fibonacci backward 144 | 8.228 | 10.553–10.804 | +0.7% |
| native printer eight maps | 0.038 | 0.080–0.102 | +0.0% |

Every text output hash matches. Host timing is noisy even for the unchanged native
printer, so the small-workload wall-time variations should not be interpreted as
uniform speedups or regressions. Quoted parsing still has approximately 1.5% more
reductions; map printing approximately 1.4% more. Unrelated splitting is back to
about 0.1% overhead. These remaining costs are visible rather than hidden in the
larger parser gain.

Before the final eligibility narrowing, heap-allocation profiling measured
73.84 MB per restored parse versus 96.19 MB with the optimizer disabled. Prepared
frames fell from 26,450 to 18,235. The original optimized implementation measured
44.4 MB and 8,019 frames. These are allocated heap bytes, not peak live memory.
The remaining preparation includes 2,854 symbol frames and 1,730 integer frames,
versus 837 and 418 in the original. This is concrete evidence for investigating
the surrounding recognition logic before attributing the residual gap to binary
matching itself.

The isolated full suite ran 1,304 tests with the same two known diagnostic
failures. After the eligibility refinement and an additional dynamic-selector
regression case, all 35 focused scan, consumption, grammar and sequence tests
passed. They cover Unicode boundaries, malformed suffixes, generation fallback,
aliases, constraints, duplicates, effects, source edits, tracing and resumption
across exhausted budgets. No shared store was reset.

Raw results, the optimizer-off control, and profiling scripts are under
`/tmp/al-scan-restoration/`. The main reproducible workload suites remain
`bench/parsing.exs` and `bench/text_operations.exs`.


## Early grammar rejection after binary migration

The negative integer rule now matches the minus sign before establishing its
arithmetic constraints. Clause rejection reuses the existing callable-inlining
analysis, so leading tests inside grammar `where` blocks are visible. It also
recognizes `not {var X}` for heads made entirely of distinct variables; heads
that can bind or alias an argument retain normal execution. This removes
printing-only alternatives from open-number parsing without changing number
syntax or adding scanner rules. A mask retaining every clause returns the
existing candidate list.

The 16-definition fixture contains no numeric literals. Previously its failed
number interpretations nevertheless performed 2,595 `require_integer/2` calls
and 20,760 `Bounds.domain_of/2` calls. The corrected allocation profile records
neither call. Integer frames fall from 1,730 to 640, and separate `natural`
frames from 2,595 to zero. Symbol frames remain 2,854: repeated symbol validation
has not been completely eliminated or replaced by the old broad scan optimizer.

Sequential isolated before/after comparisons used one scheduler, 21 checked
samples per workload and both orderings. The final parser run used 31 samples.
The control loads the saved pre-change grammar and rejection module into its
own VM; it does not mutate the checkout or use the shared store.

| 16-definition parse | Before | After |
|---|---:|---:|
| BEAM reductions | 8.13 million | 5.58 million (-31%) |
| Prepared frames | 18,235 | 14,550 (-20%) |
| Heap bytes allocated | 73.84 MB | 49.07 MB (-34%) |

The frame and allocation profiles precede the final candidate-list reuse tweak.
Allocation is total heap allocation, not peak live memory or binary storage.
The original optimized character-list implementation allocated about 44.4 MB.

Ablations measured 5.75 million reductions with only the grammar reorder and
7.95 million with only the rejection changes. Most of the benefit therefore
comes from avoiding arithmetic work on impossible negative-number parses.

Before medians were 65.4–65.6 ms. After medians were 53.7 and 70.1 ms, with the
final run at 62.0 ms. Batch CPU measurements were also variable: before
85–106 ms/parse, after 54–130 ms, and original character-list 83–103 ms. These
VM-wide CPU samples include background work and are not a clean attribution to
the parser. The evidence establishes less work and allocation; it does not
establish a stable elapsed-time percentage or a consistent lead over the
original parser.

All 17 text-suite output hashes match. Integer-list printing uses about 4.4%
fewer reductions and map-list printing 9.7% fewer. Most other workloads remain
within 0.8%, but quoted Unicode printing is +1.6%, join-through-split +4.5%, and
forward Fibonacci +1.3% in the final run. Earlier measurements of those same
changed paths were -0.3%, +1.7%, and +1.3%, respectively. Small-workload timings
vary substantially, including unchanged native printing; no uniform speedup is
claimed for the broader suite.

All 51 focused tests pass, including an explicit check that mode rejection is
exercised, head aliasing, integer prefix order, constrained generation, digit
overrides and tracing. The full suite before the final candidate-list reuse
change ran 1,308 tests with the same two known diagnostic failures:
`unmatched_clause_body_names_the_actual_call` and
`native_failed_unification_preserves_constraint_diagnostics`.
Raw measurements, snapshots and isolated comparison scripts are in
`/tmp/al-grammar-rejection/`.


## Leading-call rejection experiment

A conservative prototype propagated leading argument tests through calls on a
known receiver. It used existing loaded method IR, recorded method and
`does_not_understand` dependencies, stopped at effects and unsupported operations,
and retained normal tracing. Nested alternatives combined rejection conditions;
open arguments and possible head aliasing limited which tests could propagate.
It added no machine instruction or grammar-specific recognition rule.

Two isolated control/experiment runs in each order used 21 checked samples and
one scheduler. The five parser/text workloads retained their expected answers.

| Workload | Control reductions | Prototype reductions |
|---|---:|---:|
| 16 definitions | 5.588–5.590 million | 5.760–5.768 million (+3.1%) |
| Generate 128-character symbol | 78,812–78,829 | 82,069–82,203 (+4.2%) |

Prepared parser frames fell only from 14,550 to 14,390. The removed frames were
`spaced_exprs`; integer and symbol frame counts did not improve. In 545 calls,
the new tests rejected the last candidate. Existing selection still attempts a
matching rejected clause when no retained clause matches, preserving body
failure versus missing-method behavior and the failure explanation. Additional
rejection tests therefore did not remove those executions.

Wall-clock medians were too variable to establish a timing improvement: control
74–117 ms and prototype 90–94 ms for 16 definitions. The extra work and small
frame reduction did not justify the added analysis. The prototype was removed,
restoring all three runtime files byte-for-byte to their starting snapshots.
The earlier grammar reorder and direct mode-rejection improvements remain.
No full correctness claim is made for the discarded prototype. Source snapshots,
prototype files, frame counters and comparison results are retained under
`/tmp/al-leading-rejection/`.

## Rejected-call failure experiment

A prototype gave clause selection an explicit `{:rejected, matched_clause}`
result, distinct from no matching head. The machine could backtrack immediately
when another executable choice existed. Terminal failures still executed the
original clause for precise failure reporting; semantic tracing and pending
suspensions also retained normal execution. No instruction was added.

An alternating control/prototype/prototype/control comparison used isolated
stores, one scheduler, and 21 checked samples per workload. For 16 definitions,
control runs used 5.582–5.587 million reductions and prototype runs used
5.509–5.524 million, a reduction of about 1.2–1.4%. Wall-clock medians ranged
from 83–115 ms for controls and 59–106 ms for the prototype, too variable to
establish a timing improvement. The five workloads returned their expected
answers, and all 51 existing focused tests passed.

Loading the discarded leading-call analysis only in a benchmark process, on top
of this prototype, lowered parser reductions to 5.351 million (about 4.2% below
control). It still increased symbol-generation reductions from about 78,818 to
82,082 (+4.1%). This combined run checked benchmark answers, not the full
correctness of the discarded analysis.

Calls through the instrumented `Frame.entry/4` fell from 14,550 to 13,652 with
the failure change alone: 865 `digit` entries and 33 `class_marker` entries were
removed. The combined experiment reached 13,492, removing another 160
`spaced_exprs` entries. These counters do not count entries constructed directly
by the tail-call path.

The explicit-result prototype added 46 machine lines and needed a separate
check of whether backtracking would discard the failure, retaining ordinary
execution otherwise. The small work reduction did not deliver the intended
architectural simplification. Both edited runtime files were restored
byte-for-byte; the leading-call analysis was never restored to the checkout.
The earlier successful grammar and rejection fixes remain. Snapshots,
prototype sources, checked measurements and frame counters are under
`/tmp/al-rejected-call/`.

## Grammar pattern classification clauses

The experiment split `grammar >> pattern_kind` into separate clauses for open
variables, atoms, and bound non-atoms. The atom clause retained priority for
`known_text` and `unknown_text`. The bound non-atom clause retained the existing
class and compound tests. These cannot all be made disjoint by clause shape alone:
`class Pattern string` can bind an unknown class in a classed map, and the
generic call interpretation overlaps special compounds. No cuts were added.

The change concerns grammar rule construction. `pattern_goal` calls
`pattern_kind` while `rule_goals` constructs a rule's executable body; warmed
parsing runs the already constructed bodies.

Before/after/after/before runs used fresh isolated stores, one scheduler, and
21 checked samples per workload. All output hashes matched across versions,
including constructed goal terms after normalizing variable names.

| Workload | Before reductions | After reductions | Change |
|---|---:|---:|---:|
| Classify 96 mixed patterns | 150,450 | 154,512 | +2.7% |
| Construct goals for 96 mixed patterns | 265,137 | 280,224 | +5.7% |
| Parse 16 definitions | 5.556 million | 5.570 million | +0.24% |

Elapsed medians for classification were 0.772–1.013 ms before and
0.813–1.495 ms after; goal construction was 2.410–4.446 ms before and
5.335–6.935 ms after. Parser medians were 71.692–78.520 ms before and
99.928–119.044 ms after, with broad individual-sample variation. This is a
clause-structure refactor with a measured increase in rule-construction work,
not a parser speedup.

The 19 focused tests passed, including new checks for complete answer sets,
open patterns, open class slots, incompatible requested kinds, argument aliases,
and tracing. The full suite ran 1,310 tests with the same two known diagnostic
failures: `unmatched_clause_body_names_the_actual_call` and
`native_failed_unification_preserves_constraint_diagnostics`. Raw measurements,
the comparison script and the original bootstrap are in `/tmp/al-pattern-kind/`.

The clause split was reverted after the measured increase in construction work.
The original conditional chain is restored; the behavior tests and benchmark
findings are retained.

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

## Instruction-pair profile

```sh
ELIXIR_ERL_OPTIONS='+S 1:1 +t 4000000' BENCH_JSON=/tmp/instruction-profile.json mix run --no-start bench/instruction_profile.exs
```

Measures parser, BNF, forward/backward Fibonacci, selector/anonymous-method map,
and generative list-length workloads. Timings use the original runtime before
instrumentation. Three subsequent profiles must have identical counts and pass
each workload's result check.

The profiler instruments normal optimized execution in its isolated process;
it does not enable VM tracing or change production runtime files. Counts cover
instruction fetches, adjacent executed pairs in the same frame, example sites
grouped by caller selector and instruction positions, and executed `try`/jump
fusions. Calls, returns and retry entries separate instruction sequences.
Already fused inner operations, clause-head matching and host-side traversals
are not individual instruction fetches. Pair frequency is not a time share or
proof that the pair can safely be fused. Instrumented runs are not timed.

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

## Binary text

```sh
ELIXIR_ERL_OPTIONS='+S 1:1' BENCH_SAMPLES=11 BENCH_JSON=/tmp/binary-text.json mix run --no-start bench/binary_text.exs
```

Measures concatenation, codepoint length, splitting, formatting, nested formatting,
symbol parsing and parsing the point fixture. Inputs and expected answers are
prepared outside timing. Each sample checks its result. To compare revisions,
run this same script in each checkout with an isolated store; startup and query
parsing are excluded from the measurements.

Text grammars now consume UTF-8 binaries. The character-list symbol scanner and
its comparison harness have been removed. The generic list recurrence optimizer remains available for ordinary list relations. Earlier parser profiles below describe the workloads at the
revisions where they were collected.

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
