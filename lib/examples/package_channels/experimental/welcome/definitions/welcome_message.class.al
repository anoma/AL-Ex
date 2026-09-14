Class {
  #name : :welcome_message,
  #superclass : [:object],
  #metaclass : :class,
  #ivars : []
}

:welcome_message >> :parts, [_self, [greeting, punctuation]] [
  new(:greeter, greeter)
  greeting(greeter, greeting)
  new(:punctuator, punctuator)
  punctuation(punctuator, punctuation)
]
