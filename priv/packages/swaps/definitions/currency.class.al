Class {
  #name : :currency,
  #superclass : [:value],
  #metaclass : :class,
  #ivars : [%{name: :amount, type: :number}]
}

:currency >> :amount, [self, amount] [
  get(self, :amount, amount)
]

:currency >> :plus, [self, other, total] [
  class(self, currency_class)
  isa(other, currency_class)
  amount(self, balance_amount)
  amount(other, deposit_amount)
  total_amount = balance_amount + deposit_amount
  put(self, :amount, total_amount, total)
]

:currency >> :minus, [self, other, remainder] [
  class(self, currency_class)
  isa(other, currency_class)
  amount(self, balance_amount)
  amount(other, withdrawal_amount)
  remaining_amount = balance_amount - withdrawal_amount
  remaining_amount > 0
  put(self, :amount, remaining_amount, remainder)
]
