@owned
#{super: object, ivars: [#{name: name}, #{name: owner}, #{name: data}]}.

owned >> update
| Self Slots |
set_slots Self Slots.

owned >> may
| Self Caller _Method _Args |
ground Caller,
get Self owner Caller.

owned >> guarded_send
| Self Caller Method Args |
may Self Caller Method Args,
send Self Method Args.

owned >> does_not_understand
| Self Method [Caller, Args] |
guarded_send Self Caller Method Args.