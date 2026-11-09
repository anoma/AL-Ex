defmodule AL.Source.Ref do
  @moduledoc "An ephemeral reference from one source capture to its defining command."

  @type capture_id() :: {reference(), non_neg_integer()}
  @type t() :: %__MODULE__{
          capture_id: capture_id(),
          tx_id: non_neg_integer() | nil,
          kind: :defmethod | :defclass,
          range: AL.Syntax.Capture.source_range()
        }

  @enforce_keys [:capture_id, :kind, :range]
  defstruct [:capture_id, :tx_id, :kind, :range]
end

defmodule AL.Source.Evaluation do
  @moduledoc "A source-aware AL program prepared before its Mnesia transaction."

  @type t() :: %__MODULE__{
          text: String.t(),
          origin: AL.SourceStore.origin(),
          program: [AL.Goal.t()],
          refs: %{AL.Source.Ref.capture_id() => AL.Source.Ref.t()}
        }

  @enforce_keys [:text, :origin, :program, :refs]
  defstruct [:text, :origin, :program, :refs]
end

defmodule AL.Source.ProvenanceError do
  @moduledoc "A missing, duplicate, or mismatched source command anchor."

  defexception [:capture_id, :reason]

  @impl true
  def message(%__MODULE__{capture_id: capture_id, reason: reason}) do
    "invalid source provenance for #{inspect(capture_id)}: #{inspect(reason)}"
  end
end

defmodule AL.Source.DefinitionOrigin do
  @enforce_keys [:capture_id, :target]
  defstruct [:capture_id, :target]

  @type t :: %__MODULE__{
          capture_id: AL.Source.Ref.capture_id(),
          target: {:method, term(), term()} | {:class, term()}
        }

  def new(capture_id, :defmethod, [owner, selector | _]),
    do: %__MODULE__{capture_id: capture_id, target: {:method, owner, selector}}

  def new(capture_id, :defclass, [class | _]),
    do: %__MODULE__{capture_id: capture_id, target: {:class, class}}

  def new(capture_id, method, args) do
    :mnesia.abort(%AL.Source.ProvenanceError{
      capture_id: capture_id,
      reason: {:definition_call_mismatch, {method, args}}
    })
  end

  def context(%__MODULE__{target: {:method, owner, selector}}, store),
    do: %{class: AL.Var.subst(owner, store), method: AL.Var.subst(selector, store)}

  def context(%__MODULE__{target: {:class, class}}, store),
    do: %{class: AL.Var.subst(class, store)}
end
