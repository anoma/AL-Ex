defmodule AL.Application do
  @moduledoc """
  I am the top level OTP application callback module for AL.
  I manage both the event server and object server.
  """

  use Application
  use AL

  @impl true
  def start(_type, _args) do
    children = [
      AL.Events,
      AL.Objects
      # {DynamicSupervisor, name: QueryEngineSupervisor}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Al.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def bootstrap() do
    run do
      set_class(:class, :class)
      set_class(:behaviour, :class)

      set_super(:class, :object)
      set_super(:behaviour, :object)

      set_method(:class, :init, :initialise_class)
      set_method(:class, :allocate, :allocate_class)
      set_method(:class, :meta, :metaclass)
      set_method(:class, :new, :new_object)

      set_method(:object, :lookup, :lookup)
      set_method(:object, :send, :send)
      set_method(:object, :init, :initialise_object)

      set_class(:initialise_class, :behaviour)
      set_oapply(:initialise_class,
        [self, %{name: name, super: super, slots: slots}, _]) do

        class(self, meta)
        set_class(name, meta)
        set_super(name, super)
        set_slots(name, slots)
      end

      set_class(:allocate_class, :behaviour)
      set_oapply(:allocate_class,
        [self, %{class: self}]) do
      end

      set_class(:metaclass, :behaviour)
      set_oapply(:metaclass,
        [self, class, meta]) do
        
        class(self, class)
        class(class, meta)
      end

      set_class(:lookup, :behaviour)
      set_oapply(:lookup, [self, name, id]) do
        method(self, name, id)
      end

      set_oapply(:lookup,
        [self, name, id]) do
        
        super(self, super)
        lookup(super, name, id)
      end

      set_class(:new_object, :behaviour)
      set_oapply(:new_object,
        [self, args, new]) do
        
        send(self, :allocate, [alloc])
        send(alloc, :init, [args, new])
      end

      set_class(:send, :behaviour)
      set_oapply(:send,
        [self, method, args]) do

        class(self, class)
        implies([lookup(class, method, id)],
          [print(["calling", id, "from", class, "with args", [self | args]]),
           oapply(id, [self | args])],
          [:fail])
      end

      set_class(:initialise_object, :behaviour)
      set_oapply(:initialise_object,
        [self, _, self]) do
        print(self)
      end
    end
  end
end
