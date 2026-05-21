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

      # Implementation of logical xor
      set_oapply(:bit_xor, [false, false, false]) do end
      set_oapply(:bit_xor, [false, true, true]) do end
      set_oapply(:bit_xor, [true, false, true]) do end
      set_oapply(:bit_xor, [true, true, false]) do end

      # Implementation of logical and
      set_oapply(:bit_and, [false, false, false]) do end
      set_oapply(:bit_and, [false, true, false]) do end
      set_oapply(:bit_and, [true, false, false]) do end
      set_oapply(:bit_and, [true, true, true]) do end

      # Implementation of a half adder
      set_oapply(:half_adder, [x, y, r, c]) do
        oapply(:bit_xor, [x, y, r])
        oapply(:bit_and, [x, y, c])
      end

      # Implementation of a full adder
      set_oapply(:full_adder, [b, x, y, r, c]) do
        oapply(:half_adder, [x, y, w, xy])
        oapply(:half_adder, [w, b, r, wz])
        oapply(:bit_xor, [xy, wz, c])
      end

      # Implementation to check that number's positive
      set_oapply(:pos, [%AL.NaturalNumber { bits: [hd | tl] }]) do end

      # Implementation to check that number's more than one
      set_oapply(:gt1, [%AL.NaturalNumber { bits: [hd0 | [hd1 | tl]] }]) do end

      # Implementation of an adder
      set_oapply(:adder, [false, n, %AL.NaturalNumber { bits: [] }, n]) do end

      set_oapply(:adder, [false, %AL.NaturalNumber { bits: [] }, m, m]) do
        oapply(:pos, [m])
      end

      set_oapply(:adder, [true, n, %AL.NaturalNumber { bits: [] }, r]) do
        oapply(:adder, [false, n, %AL.NaturalNumber { bits: [true] }, r])
      end

      set_oapply(:adder, [true, %AL.NaturalNumber { bits: [] }, m, r]) do
        oapply(:pos, [m])
        oapply(:adder, [false, %AL.NaturalNumber { bits: [true] }, m, r])
      end

      set_oapply(:adder, [d, %AL.NaturalNumber { bits: [true] }, %AL.NaturalNumber { bits: [true] }, %AL.NaturalNumber { bits: [a, c] }]) do
        oapply(:full_adder, [d, true, true, a, c])
      end

      set_oapply(:adder, [d, %AL.NaturalNumber { bits: [true] }, m, r]) do
        oapply(:gen_adder, [d, %AL.NaturalNumber { bits: [true] }, m, r])
      end

      set_oapply(:adder, [d, n, %AL.NaturalNumber { bits: [true] }, r]) do
        oapply(:gt1, [n])
        oapply(:gt1, [r])
        oapply(:adder, [d, %AL.NaturalNumber { bits: [true] }, n, r])
      end

      set_oapply(:adder, [d, n, m, r]) do
        oapply(:gt1, [n])
        oapply(:gen_adder, [d, n, m, r])
      end

      # General case of the adder
      set_oapply(:gen_adder, [d, %AL.NaturalNumber { bits: [a | x] }, %AL.NaturalNumber { bits: [b | y] }, %AL.NaturalNumber { bits: [c | z] }]) do
        oapply(:pos, [%AL.NaturalNumber { bits: y }])
        oapply(:pos, [%AL.NaturalNumber { bits: z }])
        oapply(:full_adder, [d, a, b, c, e])
        oapply(:adder, [e, %AL.NaturalNumber { bits: x }, %AL.NaturalNumber { bits: y }, %AL.NaturalNumber { bits: z }])
      end

      # Finally the implementation of plus
      set_oapply(:plus, [n, m, k]) do
        oapply(:adder, [false, n, m, k])
      end

      set_oapply(:minus, [n, m, k]) do
        oapply(:plus, [m, k, n])
      end
    end
  end
end
