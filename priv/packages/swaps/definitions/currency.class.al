@currency
#{super => value, ivars => [#{name => amount, type => number}]}.

currency >> amount
| Self Amount |
get Self amount Amount.

currency >> plus
| Self Other Total |
class Self CurrencyClass,
isa Other CurrencyClass,
amount Self BalanceAmount,
amount Other DepositAmount,
= TotalAmount (+ BalanceAmount DepositAmount),
put Self amount TotalAmount Total.

currency >> minus
| Self Other Remainder |
class Self CurrencyClass,
isa Other CurrencyClass,
amount Self BalanceAmount,
amount Other WithdrawalAmount,
= RemainingAmount (- BalanceAmount WithdrawalAmount),
> RemainingAmount 0,
put Self amount RemainingAmount Remainder.