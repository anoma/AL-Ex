defmodule AL.Domino do
  @moduledoc """
  I hold everything the domino tracing model needs, grouped in one place
  because it's all set/read by the same handful of AL.ex functions
  (begin_method_scope/mark_exited/fail_scope/backtrack's redo branch,
  trace_port_call/trace_port_event) and nothing else in the interpreter
  touches it. Pure data + types here -- the logic that reads/writes me
  stays in AL.ex, just addressed through `state.domino.*` now instead of
  flat top-level fields.

  trace: the domino event log, plus interleaved raw goals when a run opts
    into vm_trace -- see `trace_event/0`.
  vm_trace_enabled?: whether this run opted into the raw-goal interleave
    (`run vm_trace: true do ... end`).
  tracepoints: snapshot (taken at eval start) of AL.Trace's live watch-set,
    for the `AL.trace(:foo)` printer -- not the trace log itself.
  traced_calls: live-printer bookkeeping, scope -> {level, depth, receiver,
    method}, so a later Exit/Redo/Fail print knows whether its own Call
    was actually traced and what it looked like.
  scopes: everything a scope's own Exit/Redo/Fail needs that isn't
    reconstructible from the trace list alone -- its parent (for
    method_exit propagation), its kind (:method vs :clause, for tagging),
    which positions were open at Call time (for describing what got
    derived), and whether it's already exited once (for Redo detection).
    One consolidated map -- these used to be four separate top-level
    AL.t() fields, all keyed by the exact same scope id.
  """
  use TypedStruct

  @type scope() :: AL.scope()

  # A var's constraint summary: `%{isa: [...], dif: [...], bounds: {lo,hi},
  # domain: [...]}`, whichever apply, `%{}` if genuinely unconstrained --
  # same shape `AL`'s `format_output_vars/2` already puts under `$constraints`.
  @type constraint_summary() :: %{optional(atom()) => term()}
  @type var_description() :: {:bound, term()} | {:open, constraint_summary()}

  # The domino tracing model's 8 port tuples (2 stacked Byrd boxes sharing
  # an edge: method dispatch wraps clause selection). Call's last field
  # describes whatever was still open walking in (against the caller's
  # store, before this call's own goals ran); Exit's describes the same
  # positions walking out (against this scope's own store at the moment it
  # finished) -- a still-open var there isn't a failure to look up, it
  # means this call only narrowed it rather than fully deciding it. Redo/
  # Fail stay bare: nothing new is known at either of those points.
  @type domino_event() ::
          {:method_call, scope(), term(), term(), [term()], %{optional(term()) => var_description()}}
          | {:method_exit, scope(), %{optional(term()) => var_description()}}
          | {:method_redo | :method_fail, scope()}
          | {:clause_call, scope(), term(), [term()], %{optional(term()) => var_description()}}
          | {:clause_exit, scope(), %{optional(term()) => var_description()}}
          | {:clause_redo | :clause_fail, scope()}

  # A raw goal or `:backtrack`/`:flounder` control marker only joins
  # `trace` when a run opts in -- see moduledoc.
  @type trace_event() :: domino_event() | AL.Goal.t() | :backtrack | :flounder

  @type scope_info() :: %{
          parent: scope() | nil,
          kind: :method | :clause,
          open_vars: [term()],
          exited: boolean()
        }

  typedstruct enforce: true do
    field(:trace, [trace_event()], default: [])
    field(:vm_trace_enabled?, boolean(), default: false)
    field(:tracepoints, MapSet.t(), default: MapSet.new())
    field(:traced_calls, %{optional(scope()) => tuple()}, default: %{})
    field(:scopes, %{optional(scope()) => scope_info()}, default: %{})
  end
end
