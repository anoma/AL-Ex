defmodule AL do
  alias AL.JAM.State

  @moduledoc """
  Runs AL programs and returns their transaction result with explicitly awaited completions.
  """

  defstruct [:handle, :kind, :result, children: []]

  @type t() :: %__MODULE__{
          handle: term(),
          kind: :transaction | :effect | :completion,
          result: term(),
          children: [t()]
        }

  defmacro __using__(_opts) do
    quote do
      import AL
    end
  end

  defdelegate trace(point), to: AL.Trace
  defdelegate untrace(point), to: AL.Trace
  defdelegate notrace(), to: AL.Trace
  defdelegate tracepoints(), to: AL.Trace
  defdelegate await_completion(target, options \\ []), to: AL.Runner.Completion, as: :await
  defdelegate await_effect(effect, options \\ []), to: AL.Edge, as: :await

  @doc """
  Executes AL source text in one transaction.

  `bindings:` supplies initial values for named AL variables. `branch:` selects
  a branch, and `trace:` selects retained trace families. The returned `%AL{}`
  contains the transaction's result and its explicitly awaited completions.
  `wait_timeout:` limits each wait in milliseconds (default 5,000) or is `:infinity`.
  A child's failure or timeout leaves its parent's committed result intact.
  """
  def run(text) when is_binary(text), do: run(text, AL.Branch.head(), [])

  def run(text, opts) when is_binary(text) and is_list(opts) do
    {branch, opts} = Keyword.pop(opts, :branch)
    run(text, branch || AL.Branch.head(), opts)
  end

  def run(text, branch) when is_binary(text), do: run(text, branch, [])

  def run(text, branch, opts) when is_binary(text) do
    {wait_timeout, opts} = Keyword.pop(opts, :wait_timeout, 5_000)
    {bindings, transaction_opts} = Keyword.pop(opts, :bindings, %{})
    {source_tag, transaction_opts} = Keyword.pop(transaction_opts, :source_tag)
    initial_store = Map.new(bindings, fn {name, value} -> {AL.Var.var(name), value} end)
    branch = if match?(%AL.Branch{}, branch), do: branch, else: %AL.Branch{id: branch}
    origin = if source_tag == nil, do: %{kind: :al_text}, else: %{kind: :al_text, tag: source_tag}

    with {:ok, result} <- AL.Syntax.parse(text) do
      eval_with_retained_source(
        result,
        text,
        origin,
        initial_store,
        branch,
        transaction_opts
      )
      |> post_commit(wait_timeout: wait_timeout)
    end
  end

  @doc false
  @spec eval_with_retained_source(
          AL.Syntax.Result.t(),
          String.t(),
          AL.SourceStore.origin(),
          AL.Var.store() | nil,
          AL.Branch.t(),
          keyword()
        ) ::
          {:atomic, {%{String.t() => AL.Var.t()}, map(), State.t()}}
          | {:aborted, term()}
          | {:error, term()}
  def eval_with_retained_source(result, text, origin, initial_store, branch, opts) do
    with {:ok, source} <- AL.Source.prepare(result, origin, text) do
      eval_program(source.program, initial_store, branch, opts, source)
    end
  end

  @doc """
  Evaluates a goal list in a Mnesia transaction without dispatching external work.
  Returns `{:atomic, {bindings, constraints, state}}` or `{:aborted, reason}`.
  Pass a committed result to `AL.post_commit/1` to dispatch its work and collect
  its registered completions.
  """
  @spec eval([AL.Goal.t()], AL.Var.store() | nil, AL.Branch.t(), keyword()) ::
          {:atomic, {%{String.t() => AL.Var.t()}, map(), State.t()}}
          | {:aborted, term()}
  def eval(program, initial_store \\ nil, branch \\ AL.Branch.head(), opts \\ []) do
    eval_program(program, initial_store, branch, opts, nil)
  end

  defdelegate eval_program(program, initial_store, branch, opts, source), to: AL.Runner.Driver
  defdelegate has_potential_solution?(state), to: AL.JAM
  defdelegate next_solution(state), to: AL.Runner.Driver
  defdelegate notify_outbox(result), to: AL.Runner.Driver
  defdelegate post_commit(result, options \\ []), to: AL.Runner.Driver
end
