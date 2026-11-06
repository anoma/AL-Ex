@brick_list
#{
  super => brick_control,
  ivars => [
    #{
      name => items_source,
      type => observable_list,
      xaml => xaml_binding_property
    }
  ]
}.

brick_list >> init
| Self Items Self |
isa Items list,
new observable_list Items Observable,
set_slot Self items_source Observable.

brick_list >> init
| Self Items Self |
isa Items observable_list,
set_slot Self items_source Items.

brick_list >> xaml_tag
| _Self "ListBox" |.