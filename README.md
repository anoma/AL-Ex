# AL

AL is a live, ACID, bitemporal, relational-object operating system built around an append-only command log. It combines inspiration from:

- XTDB

- GlamorousToolkit/Pharo

- Git

- PROLOG/Logtalk

- LISP

- BEAM

- Urbit


The goal of the system is to merge the ideas of the relational paradigm and of the metaobject protocol, and, as a north star, to be the personal computing environment of the future.
This runtime is the prototypical version of AL, written in Elixir. The irony of the first Erlang interpreter having been written in PROLOG is not lost on us.

## Features

- Objects defined relationally, with multiple inheritance and bidirectional dispatch. An unbound receiver turns a call into a search.
- Durable by default. Every change is logged to disk. Restart and continue where you left off.
- ACID transactions.
- Constraint solving over finite domains: bounds consistency, `dif`, global constraints like `all_dif` (Régin's algorithm). Objects can be reasoned about via constraints.
- Git-like branching. Fork state, work in isolation, discard or keep.
- Execution tracing. Every run reconstructs a derivation tree: what was called, what was asserted, what it resolved to.
- Nascent bitemporality features: Query objects as of certain times, working with system and business time separately

For discussion of the design philosophy of AL and resources that were consulted during its design, please see: 
https://forum.anoma.net/t/design-philosophy-of-al-bibliography/2698

## Quickstart

Install from terminal using `iex -S mix` or as a mix dependency.
From IEx, you can run `require AL`.

`lib/examples` contains examples.
`lib/AL/transaction_program` contains the bundled transaction programs (`bootstrap` establishes the language).
`lib/AL` contains the runtime code.

A transaction program is named executable AL code, defined with
`use AL.TransactionProgram` and `defprogram`. Its `install/0` function executes
the body atomically and creates a `:program_execution` receipt linked to the
transaction. Bodies can define classes and methods or create and update data.
Dependencies order execution. Startup compares both the recorded name and
version, allowing an updated program to replace its execution receipt after its
body performs the required redefinitions.

Startup programs are configured with `config :al, transaction_programs: [...]`.
Package sources and the desired package roots are configured separately:

```elixir
config :al,
  package_channels: [{:builtin, {:priv, "packages"}}],
  package_environment: [:interval, :users, :elixir_process]
```

Use `AL.TransactionProgram`, `defprogram`, and `:transaction_programs`; the former
package API and configuration aliases have been removed. Historical `:package`
receipts remain readable through internal migration support. New receipts use
`:program_execution`, without rewriting old transactions.

The term *package* is reserved for package classes and the build system.
`:package` is now a metaclass for package classes, and instances of those classes
are concrete package builds. The class identity is the package name. Channels
hold durable provider objects containing source, version, and symbolic dependency
requirements. Realised builds reference the provider that produced them and the
exact builds chosen for every dependency. Package metadata is durable and
branch-specific.

Channels discover portable package bundles separately from the live `src/al`
projection. A bundle contains a literal `package.al` manifest and Tonel-like
class or extension documents under `definitions/`. Directory containment
establishes which definitions belong to the package, so the manifest does not
repeat members or list executable transactions. Discovery registers each channel
provider in AL. The stateless `:package_resolver` relation searches the frozen,
ordered provider list and backtracks when a preferred provider cannot satisfy
the complete dependency graph. Elixir validates the dependency-first solution
and turns it into an exact build plan. Requirements may be package names or
`{package, requirement}` pairs. The resolver uses the package name only to find
the MOP receiver and passes the complete requirement term to that package's
`accepts_build` protocol. Realisation creates or reuses build instances by their
content digest without installing their definitions; activation then applies
the source retained by their providers and records each package class's
`active_build`.
Activation treats a `Class` document as the origin of a class and an
`Extension` document as a contribution to a class originated by a dependency.
It composes their methods and superclass edges into the live class while
retaining the attribution through `originates_class`, `adds_method`,
`adds_superclass`, and `extends_class`. The package manifest does not repeat
this information.
`AL.Package.source_snapshot/2` uses those relations to capture only the active
package's current live definitions. `AL.Package.diff/2` compares that snapshot
with the parsed provider documents and reports semantic class, method, and
superclass changes without treating formatting differences as changes. Changes
and removals to loaded contributions are detected. An otherwise unclaimed
method or superclass added to a class defaults to the build that originates
that class. New classes and changes to foreign classes will require
package-attributed transactions.
Ordinary startup hydrates the retained image without re-running package
resolution. Configured packages are applied when the package system is first
introduced into an image. Call
`AL.Package.update_configured/0` to rediscover changed channel contents and
activate newly selected builds. `AL.Package.import/2` remains available for
direct, additive bundle import. Interval, Users, and Elixir Process are bundled
under `priv/packages`.

`AL.Package.ensure_configured/0` treats the configured package environment as
required roots and keeps additional live packages, including open working
packages. An explicit `AL.Package.update_configured/0` replaces the active set
with the exact configured environment.

Packages can be born in the live system with an empty open build:

```elixir
AL.run do
  new(:package, %{name: :my_package, version: 1, deps: []}, :my_package)
  active_build(:my_package, build)

  defclass :my_class, super: :object
  include_class(build, :my_class)
end
```

`include_class` attributes the class, its current methods, and its superclass
edges to the open build. `include_method` and `include_superclass` attribute
individual extension contributions. The package constructor resolves declared
requirements to their currently active builds.

An active package's current filtered source can then be exported directly:

```elixir
AL.Package.export(:my_package, to: "path/to/channel/my_package")
```

The first export registers the resulting source as a direct provider, computes
the build digest, and seals the same build as `:complete`. Later exports use the
active provider manifest as their default version and requirements. Export
rewrites `package.al` and makes `definitions/` match the package-filtered
snapshot. The resulting directory can also be discovered through a channel.

The paired channels under `lib/examples/package_channels/stable` and
`lib/examples/package_channels/experimental` demonstrate provider selection.
Both offer `:greeting`, `:punctuation`, and the dependent `:welcome` package.
Their Greeting sources differ, their Punctuation sources are identical, and
their Welcome sources are identical but depend on Greeting. Reversing channel
priority therefore reuses the Punctuation build while producing new Greeting
and Welcome builds. The runnable example is
`Examples.ALPackages.channels_offer_providers_and_builds_track_dependency_choices/0`.

The files under `src/al` are projections of the store. On startup, AL regenerates
them from the store: offline definition edits are overwritten, deleted files are
restored, and extra definition files are removed. Only definition edits observed
while AL's serialiser is running are imported as new transactions. If the store
is missing, the configured transaction programs and package environment rebuild
it and the files are regenerated from that new state. Transaction files in the
live projection are history and are never executed automatically.

## Livebooks

The fastest way to try AL is [`livebooks/intro.livemd`](livebooks/intro.livemd) and the notebooks it links to. `mix escript.install hex livebook` followed by `livebook server` gets you Livebook itself if you don't already have it.

## Working with multiple sessions at once

AL persists to a local, gitignored Mnesia store (`.mnesiastore/` by default) that every `iex -S mix`/`mix run`/`mix test` invocation in a checkout shares unless told otherwise.

You can utilise forks to have multiple streams work on the same node without conflict. 

```elixir
fork = AL.Branch.fork() <- fork from HEAD
AL.Branch.checkout(fork) <- change HEAD to fork
AL.Branch.discard(fork) <- discard the fork
```

Further isolation should be accomplished by configuration of the Mnesiastore dir.

## Working with the live AL node over MCP

The AL owner node starts an MCP server on `http://127.0.0.1:3031/mcp`. Joining
BEAM nodes use the owner's Mnesia tables and do not start competing MCP
listeners. The server is disabled in the test environment.

Add it to Codex with:

```console
codex mcp add almcp --url http://localhost:3031/mcp
```

The repository's `.codex/config.toml` already contains this project-level
connection. Add it to Claude Code with:

```console
claude mcp add --transport http --scope project almcp http://localhost:3031/mcp
```

The initial tools are:

- `evaluate` evaluates Elixir inside the live owner node for inspection and
  administration.
- `evaluateSource` parses, retains, and evaluates complete AL source on an
  existing branch. It uses AL's normal transaction machinery and returns the
  committed or failed transaction object.
- `listBranches` identifies the current HEAD and each branch's command-log
  position.

The server binds only to loopback. Its `evaluate` tool provides arbitrary code
execution to local MCP clients, like GT MCP's evaluator.

## Installing into Glamorous Toolkit

The bundled Lepiter notebook **Working with AL in GT** covers bridge setup,
connection checks, object inspection, and troubleshooting. After loading the
baseline below, register it in GT with:

```st
BaselineOfAL loadLepiter
```

For a local Tonel load or a checkout not registered as `AL-Ex` in Iceberg:

```st
BaselineOfAL loadLepiterFrom: '/path/to/AL-Ex'
```

The database is stored in `lepiter/`. Edit its page in GT and include the
resulting files in the same review as related code changes. Registration does
not start an Elixir runtime or execute the notebook's setup snippets.

```st
Metacello new
	repository: 'github://anoma/AL-Ex:base/src/gt';
	baseline: 'AL';
	load
```

If you have an existing bridge with a different version you want to run this without error then run:

```st
Metacello new
	repository: 'github://anoma/AL-Ex:base/src/gt';
	baseline: 'AL';
	load: #dev
```
