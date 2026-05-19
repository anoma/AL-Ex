defmodule AL.Application do
  @moduledoc """
  I am the top level OTP application callback module for AL.
  I manage both the event server and object server.
  """

  use Application
  use AL

  @impl true
  def start(_type, _args) do
    AL.Command.setup()
    AL.Objects.setup()

    opts = [strategy: :one_for_one, name: Al.Supervisor]
    {:ok, pid} = Supervisor.start_link([AL.Scheduler], opts)

    bootstrap()

    {:ok, pid}
  end

  def bootstrap() do
    case :mnesia.table_info(:command, :size) do
      0 -> do_bootstrap()
      _ -> :ok
    end
  end

  defp do_bootstrap() do
    run do
      set_class(:class, :class)
      set_class(:behaviour, :class)

      set_super(:class, :object)
      set_super(:behaviour, :object)

      set_method(:class, :init, :initialise_class)

      set_method(:object, :lookup, :lookup)
      set_method(:object, :send, :send)
      set_method(:object, :meta, :metaclass)
      set_method(:object, :defmethod, :defmethod)

      set_class(:initialise_class, :behaviour)

      set_oapply(
        :initialise_class,
        [self, args, name]
      ) do
        map_get(args, :name, name)
        map_get(args, :super, super)
        map_get(args, :slots, slots)

        class(self, meta)
        
        set_class(name, meta)
        set_super(name, super)
        set_slots(name, slots)
      end

      set_class(:metaclass, :behaviour)

      set_oapply(:metaclass, [self, class, meta]) do
        class(self, class)
        class(class, meta)
      end

      set_class(:lookup, :behaviour)
      set_oapply(
        :lookup,
        [self, name, id]
      ) do
        alternative([method(self, name, id)],
          [super(self, super),
           lookup(super, name, id)])
        # super(self, super)
        # lookup(super, name, id)
      end

      set_oapply(:lookup, [self, name, id]) do
        method(self, name, id)
      end

      set_class(:send, :behaviour)

      set_oapply(
        :send,
        [self, method, args]
      ) do
        class(self, class)
        implies(
          [lookup(class, method, id)],
          [
            print(["calling", id, "from", class, "with args", [self | args]]),
            oapply(id, [self | args])
          ],
          [:fail]
        )
      end

      set_class(:defmethod, :behaviour)
      set_oapply(:defmethod, [self, method_name, head, body]) do
        gensym(impl)
        set_method(self, method_name, impl)
        set_class(impl, :behaviour)
        set_oapply(impl, head, body)
      end

      set_class(:map_get, :behaviour)
      set_method(:map, :map_get, :map_get)

      defmethod(:class, :allocate, [self, %{class: self}]) do
      end

      defmethod(:class, :new, [self, args, new]) do
        send(self, :allocate, [alloc])
        send(alloc, :init, [args, new])
      end

      defmethod(:object, :init, [self, _, self]) do
        print(self)
      end

      lookup(:class, :init, n)
      send(:class, :new, [%{name: :process, super: :object, slots: []}, _])      
      defmethod(:process, :init, [self, args, new_obj]) do
        map_get(args, :head, head)
        map_get(args, :body, body)
        gensym(new_obj)
        spawn_process(new_obj, head, body)
      end
    end
  end
end
