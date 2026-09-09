defmodule AL.Native do
  @moduledoc """
  Registers Elixir-implemented "native" methods -- genuinely new capability
  AL cannot express itself (e.g. calling Nx), as opposed to a jet-style
  accelerant of *existing* AL behavior (out of scope here on purpose: see
  register/6's `force` guard below).

  A native's *binding* -- "method X is native, backed by
  {module,function,arity,style} Y" -- is a durable, bitemporal, forkable AL
  fact (a :native key on the method_id's own row family in the :soa table,
  via AL.Object.set_native/4 / get_native/2). A native's *implementation*
  is never durable: it's ordinary compiled Elixir code, only ever callable
  from the running BEAM node that registered it (AL.Native.Registry).
  Taking the image down loses the implementation, not the fact that one is
  expected -- a missing implementation against an existing durable fact is
  a loud, named diagnostic (see the :native_missing/:native_mismatch cases
  in AL.ex's format_failure/1), never a silent DNU or a silent fallback.

  Two author styles, tagged in the durable fact:

    - `:value` (default) -- the wrapped function is an ordinary Elixir
      function with no AL awareness (literally `Nx.add/2`). `call_args` is
      `inputs ++ [output]`: every position but the last is a ground input
      passed positionally to `apply(module, function, ground_inputs)`; the
      last position is unified with whatever the function returns.

    - `:raw` -- the wrapped function has the exact `(call_args, state) ::
      AL.t() | nil` contract `AL.interp/2` itself has. Full responsibility
      for groundness/constraint handling, and free to use `AL.fan_out/3`
      to produce multiple solutions (natives may be nondeterministic).
  """

  require AL

  @type style :: :value | :raw

  @doc """
  Declares `class`'s `selector` (wrapping `module.function/arity`) as
  native. Two-part effect: (1) makes the implementation callable in this
  running image (AL.Native.Registry), and (2) on first registration,
  writes the durable :native fact if none exists yet for this method_id.

  Idempotent against an identical prior registration -- this is what makes
  calling `register/5,6` again on every boot (see AL.Application,
  `register_all/1`) safe, and is how a native's binding "survives" an
  image restart: the durable fact does, the implementation doesn't, and
  this re-satisfies it automatically for every native the current image's
  config still knows how to provide.

  Options:
    - `:style` -- `:value` (default) or `:raw`.
    - `:force` -- `false` (default). Registering a native against a
      method_id that already has real interpreted `oapply` clauses raises
      unless this is `true` -- shadowing existing interpreted behavior is
      functionally what a jet would do, not a native, so it's rejected by
      default rather than silently allowed.
    - `:branch` -- defaults to `AL.Branch.head()`.

  Raises if the wrapped function isn't exported, if a durable native fact
  already exists for this method_id and disagrees with the attempted
  binding, or if `:force` was needed but not given.
  """
  @spec register(atom(), atom(), module(), atom(), non_neg_integer(), keyword()) ::
          {:ok, term()}
  def register(class, selector, module, function, arity, opts \\ []) do
    style = Keyword.get(opts, :style, :value)
    force = Keyword.get(opts, :force, false)
    branch = Keyword.get(opts, :branch, AL.Branch.head())
    mfa = {module, function, arity, style}

    unless function_exported?(module, function, arity) do
      raise "AL.Native: #{inspect(module)}.#{function}/#{arity} is not exported"
    end

    case :mnesia.transaction(fn -> do_register(class, selector, mfa, force, branch) end) do
      {:atomic, method_id} ->
        :ok = AL.Native.Registry.put(method_id, mfa)
        {:ok, method_id}

      {:aborted, {:native_conflict, method_id, existing, attempted}} ->
        raise "AL.Native: durable log already declares #{inspect(class)}##{selector} " <>
                "(#{inspect(method_id)}) as backed by #{inspect(existing)}, refusing to " <>
                "register #{inspect(attempted)} under the same method_id -- call " <>
                "AL.Native.retract/2 first if this is an intentional change."

      {:aborted, {:has_interpreted_clauses, method_id}} ->
        raise "AL.Native: #{inspect(class)}##{selector} (#{inspect(method_id)}) already has " <>
                "real interpreted clauses -- registering a native here would shadow them, " <>
                "which is functionally a jet, not a native (out of scope). Pass force: true " <>
                "to override."

      {:aborted, reason} ->
        raise "AL.Native: registration failed: #{inspect(reason)}"
    end
  end

  # tx_id minted once, here, and threaded through every command this one
  # registration writes (set_method, if a fresh method_id is needed, and
  # set_native) -- the same pattern eval_transaction/5 and next_solution/1
  # use for state.tx_id (lib/AL.ex): one snapshot of "now" per logical
  # transaction, not re-read per command, so commands_for_transaction/2
  # can find every write this registration made as one group.
  defp do_register(class, selector, mfa, force, branch) do
    tx_id = AL.Command.system_time(branch)
    method_id = find_or_create_method_id(class, selector, tx_id, branch)

    if not force and has_interpreted_clauses?(method_id, branch) do
      :mnesia.abort({:has_interpreted_clauses, method_id})
    end

    case AL.Object.get_native(method_id, branch) do
      nil ->
        tx = AL.Command.set_native(tx_id, method_id, mfa, branch)
        AL.Object.set_native(method_id, mfa, tx, branch)
        method_id

      ^mfa ->
        method_id

      other ->
        :mnesia.abort({:native_conflict, method_id, other, mfa})
    end
  end

  defp find_or_create_method_id(class, selector, tx_id, branch) do
    case AL.Object.scan_method(class, selector, :"$id", branch) do
      [{:method, ^class, ^selector, id} | _] ->
        id

      [] ->
        id = AL.Command.fresh_id(branch)
        tx = AL.Command.set_method(tx_id, class, selector, id, branch)
        AL.Object.set_method(class, selector, id, tx, branch)
        id
    end
  end

  defp has_interpreted_clauses?(method_id, branch),
    do: AL.Object.scan_oapply(method_id, :"$seq", :"$head", :"$body", branch) != []

  @doc "Un-declares a native: closes the durable fact, removes the ephemeral implementation."
  @spec retract(term(), keyword()) :: :ok
  def retract(method_id, opts \\ []) do
    branch = Keyword.get(opts, :branch, AL.Branch.head())

    :mnesia.transaction(fn ->
      case AL.Object.get_native(method_id, branch) do
        nil ->
          :ok

        mfa ->
          tx = AL.Command.retract_native(AL.Command.system_time(branch), method_id, mfa, branch)
          AL.Object.retract_native(method_id, mfa, tx, branch)
      end
    end)

    AL.Native.Registry.delete(method_id)
    :ok
  end

  @doc """
  Registers every `{class, selector, module, function, arity}` or
  `{class, selector, module, function, arity, opts}` entry in `entries`,
  tolerating individual failures -- one bad entry (e.g. a module not
  loaded in this deployment) must not block boot. Called from
  AL.Application after `bootstrap/0`, driven by `config :al, natives:
  [...]` -- the same "re-run on every boot" pattern transaction programs already use.
  """
  @spec register_all([tuple()]) :: :ok
  def register_all(entries) do
    for entry <- entries do
      try do
        apply(__MODULE__, :register, Tuple.to_list(entry))
      rescue
        e ->
          IO.warn("AL.Native: failed to register #{inspect(entry)}: #{Exception.message(e)}")
      end
    end

    :ok
  end

  @doc false
  @spec dispatch(term(), [term()], AL.t()) :: :not_native | {:handled, AL.t() | nil}
  def dispatch(method_id, call_args, state) do
    case AL.ResolutionCache.fetch_native(state.branch, method_id, fn ->
           AL.Object.get_native(method_id, state.branch)
         end) do
      nil ->
        :not_native

      {module, function, arity, style} = mfa ->
        case AL.Native.Registry.lookup(method_id) do
          ^mfa ->
            {:handled, run(style, module, function, arity, method_id, call_args, state)}

          nil ->
            {:handled, AL.backtrack(record_native_missing(state, method_id, mfa))}

          other ->
            {:handled, AL.backtrack(record_native_mismatch(state, method_id, mfa, other))}
        end
    end
  end

  defp run(:raw, module, function, _arity, _method_id, call_args, state),
    do: apply(module, function, [call_args, state])

  defp run(:value, module, function, _arity, method_id, call_args, state) do
    {inputs, [output]} = Enum.split(call_args, length(call_args) - 1)
    store = state.active_choicepoint.store

    case first_open_position(inputs, store) do
      {:error, position} ->
        AL.backtrack(record_input_not_ground(state, method_id, position))

      :ok ->
        ground_inputs = Enum.map(inputs, &AL.Var.deref(store, &1))

        try do
          result = apply(module, function, ground_inputs)
          AL.put_bindings(state, AL.unify(state, output, result), [output])
        rescue
          e -> AL.backtrack(record_native_error(state, method_id, {module, function}, e))
        end
    end
  end

  defp first_open_position(inputs, store) do
    inputs
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {v, i} ->
      if AL.Var.var?(AL.Var.deref(store, v)), do: {:error, i}, else: false
    end)
  end

  # Every entry below is a tagged 2-tuple ({:tag, payload}), not a flat
  # N-tuple -- see the matching comment in AL.ex's format_failure/1, whose
  # pre-existing DNU clause would otherwise silently swallow any
  # same-arity native diagnostic tuple regardless of its actual tag.
  defp record_native_missing(state, method_id, mfa) do
    entry = {state.active_choicepoint.scope_pointer, {:native_missing, {method_id, mfa}}}
    %AL{state | diagnostics: [entry | state.diagnostics]}
  end

  defp record_native_mismatch(state, method_id, expected, actual) do
    entry =
      {state.active_choicepoint.scope_pointer, {:native_mismatch, {method_id, expected, actual}}}

    %AL{state | diagnostics: [entry | state.diagnostics]}
  end

  defp record_input_not_ground(state, method_id, position) do
    entry =
      {state.active_choicepoint.scope_pointer, {:native_input_not_ground, {method_id, position}}}

    %AL{state | diagnostics: [entry | state.diagnostics]}
  end

  defp record_native_error(state, method_id, {module, function}, exception) do
    entry =
      {state.active_choicepoint.scope_pointer,
       {:native_error, {method_id, {module, function}, Exception.message(exception)}}}

    %AL{state | diagnostics: [entry | state.diagnostics]}
  end
end
