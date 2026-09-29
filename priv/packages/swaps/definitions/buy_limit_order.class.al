@buy_limit_order
#{
  super: object,
  ivars: [
    #{name: pool, type: pool},
    #{name: condition, type: anonymous_method},
    #{default: open, domain: [open, filled], name: status},
    #{name: filled_swap, type: swap}
  ]
}.

buy_limit_order >> init
| Self Args Self |
call_next_method Self Args Self,
get Self pool Pool,
place_order Pool Self.

buy_limit_order >> constrain
| Self Trade |
get Self condition Condition,
run Condition [Trade].

buy_limit_order >> ready
| Self Trade |
get Self status open,
constrain Self Trade,
get Self pool Pool,
quote Trade Pool.

buy_limit_order >> fill
| Self Trade |
ready Self Trade,
complete Self Trade.

buy_limit_order >> complete
| Self Trade |
get Self pool Pool,
execute Trade Pool,
set_slots Self #{filled_swap: Trade, status: filled},
remove_order Pool Self,
after_fill Self Trade.

buy_limit_order >> try_fill
| Self |
ready Self Trade -> complete Self Trade ; pass.

buy_limit_order >> after_fill
| _Self _Trade |.

buy_limit_order >> change_condition
| Self Condition |
set_slot Self condition Condition.

buy_limit_order >> would_have_filled_at
| Self Time Trade |
constrain Self Trade,
get Self pool Pool,
quote_at Trade Pool Time.