defmodule ALSyntaxReaderTest do
  use ExUnit.Case, async: true

  alias AL.Goal
  alias AL.Syntax
  alias AL.Syntax.Error

  test "definition captures slice back to exactly their forms" do
    text = ~S"""
    point >> x
    | Self X |
      get Self x X.

    @point #{super => object}.
    """

    {:ok, result} = Syntax.parse(text)
    [method, class] = result.captures

    assert {:ok, "point >> x\n| Self X |\n  get Self x X"} = Syntax.slice(text, method.range)
    assert {:ok, "@point \#{super => object}"} = Syntax.slice(text, class.range)
    assert method.path == [1]
    assert class.path == [2]
  end

  test "a method head sits between bars, with an optional rest after a full stop" do
    {:ok, %{program: program}} =
      Syntax.parse(~S"""
      list >> fold_left
      | [] _Func Acc Acc |.

      object >> forward
      | Self . Args |
        ground Args.
      """)

    assert [
             %Goal.OApply{method_id: :clear_method, args: [:list, :fold_left]},
             %Goal.OApply{
               method_id: :defmethod,
               args: [:list, :fold_left, [[], :"$_Func", :"$Acc", :"$Acc"], []]
             },
             %Goal.OApply{method_id: :clear_method, args: [:object, :forward]},
             %Goal.OApply{
               method_id: :defmethod,
               args: [:object, :forward, [:"$Self" | :"$Args"], [%Goal.Ground{}]]
             }
           ] = program
  end

  test "one source's clauses for a selector define it, and only the first clears it" do
    {:ok, %{program: program}} =
      Syntax.parse(~S"""
      list >> size
      | [] 0 |.

      list >> other
      | _ |.

      list >> size
      | [_ . T] N |
        size T M,
        = N (+ M 1).

      defmethod list size [extra] {pass}.
      """)

    assert [
             %Goal.OApply{method_id: :clear_method, args: [:list, :size]},
             %Goal.OApply{method_id: :defmethod, args: [:list, :size | _]},
             %Goal.OApply{method_id: :clear_method, args: [:list, :other]},
             %Goal.OApply{method_id: :defmethod, args: [:list, :other | _]},
             %Goal.OApply{method_id: :defmethod, args: [:list, :size | _]},
             %Goal.OApply{method_id: :defmethod, args: [:list, :size, [:extra], [%Goal.Pass{}]]}
           ] = program

    assert {:ok, %{program: ^program}} = Syntax.parse(AL.Syntax.Printer.program(program))
  end

  test "list tails, negative numbers, strings, maps and quoted atoms read as data" do
    {:ok, result} =
      Syntax.parse(~S"""
      = [H . T] [-1, "a \"b\"", #{k => 'odd atom', 2 => nil}, 2.5].
      """)

    assert [%Goal.Eq{a: [:"$H" | :"$T"], b: [-1, "a \"b\"", %{:k => :"odd atom", 2 => nil}, 2.5]}] =
             result.program
  end

  test "a call takes single-term arguments, so nested calls are bracketed" do
    {:ok, %{program: [call, zero]}} = Syntax.parse("between Self (+ Low 1) High V, = X (foo).")

    assert %Goal.Send{
             method: :between,
             object: :"$Self",
             args: [%Goal.OApply{method_id: :+}, :"$High", :"$V"]
           } = call

    assert %Goal.Eq{b: %Goal.OApply{method_id: :foo, args: []}} = zero
  end

  test "commas bind loosest, so conditionals and alternatives need no brackets" do
    {:ok, %{program: program}} = Syntax.parse("a X, > X 1 -> b ; c, d X.")

    assert [
             %Goal.Send{method: :a},
             %Goal.Implies{
               condition: [%Goal.Compare{op: :>}],
               then: [%Goal.OApply{method_id: :b}],
               otherwise: [%Goal.OApply{method_id: :c}]
             },
             %Goal.Send{method: :d}
           ] = program

    assert {:ok, %{program: [%Goal.Implies{otherwise: [%Goal.Fail{}]}]}} =
             Syntax.parse("> X 1 -> = Y 2.")

    assert {:ok, %{program: [%Goal.Or{or: [%Goal.Eq{}], then: [%Goal.Eq{}, %Goal.Eq{}]}]}} =
             Syntax.parse("= X 1 ; {= X 2, = Y 3}.")
  end

  test "operators are prefix calls, nested with brackets" do
    {:ok, %{program: [%Goal.Eq{b: sum}]}} = Syntax.parse("= X (- (+ 1 (* 2 (** 3 2))) (- (4))).")

    assert %Goal.OApply{
             method_id: :-,
             args: [
               %Goal.OApply{
                 method_id: :+,
                 args: [
                   1,
                   %Goal.OApply{
                     method_id: :*,
                     args: [2, %Goal.OApply{method_id: :**, args: [3, 2]}]
                   }
                 ]
               },
               %Goal.OApply{method_id: :-, args: [4]}
             ]
           } = sum
  end

  test "an operator is an ordinary atom, and a touching minus makes a negative number" do
    {:ok, %{program: [functor, negative, negate]}} =
      Syntax.parse("functor G < [X, 10], = Y -1, = Z (- 1).")

    assert %Goal.Functor{term: :"$G", name: :<, args: [:"$X", 10]} = functor
    assert %Goal.Eq{a: :"$Y", b: -1} = negative
    assert %Goal.Eq{a: :"$Z", b: %Goal.OApply{method_id: :-, args: [1]}} = negate
  end

  test "comments are kept in method bodies only, and a map is not a comment" do
    {:ok, result} = Syntax.parse("# top\nc >> m\n| Self |\n  # body\n  pass.\n= X \#{}.")

    assert [
             %Goal.OApply{method_id: :clear_method},
             %Goal.OApply{method_id: :defmethod, args: [:c, :m, [:"$Self"], body]},
             %Goal.Eq{b: %{}}
           ] = result.program

    assert [%Goal.Comment{text: " body"}, %Goal.Pass{}] = body
  end

  test "malformed input reports where it went wrong" do
    assert {:error, %Error{phase: :parse, line: 1, message: "expected ) but found" <> _}} =
             Syntax.parse("get (Self x X.")

    assert {:error, %Error{phase: :parse}} = Syntax.parse("pass")
    assert {:error, %Error{phase: :parse}} = Syntax.parse("X =.")
    assert {:error, %Error{phase: :compile}} = Syntax.parse("@point [].")
    assert {:error, %Error{phase: :parse}} = Syntax.parse("@point \#{super => object} {}")
    assert {:error, %Error{phase: :parse}} = Syntax.parse("= M \#{key: value}.")
    assert {:error, %Error{phase: :parse}} = Syntax.parse("point >> x Self.")
    assert {:error, %Error{phase: :compile}} = Syntax.parse("{pass}.")
  end

  test "a syntax error inside run is a compile error at its line" do
    source = """
    defmodule ALSyntaxReaderTest.Broken do
      use AL

      def go do
        run do
          ~AL\"\"\"
          pass.
          = X (f Y.
          \"\"\"
        end
      end
    end
    """

    error = assert_raise CompileError, fn -> Code.compile_string(source, "broken.ex") end
    assert error.line == 8
    assert Exception.message(error) =~ "expected )"
  end
end
