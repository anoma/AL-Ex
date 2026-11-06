@brick_class_methods
#{
  super => brick,
  ivars => [
    #{name => target},
    #{name => package_options, type => list},
    #{name => filters, type => method_filters},
    #{name => sources, type => observable_list},
    #{name => rows, type => observable_list},
    #{name => edits, type => list},
    #{name => focus},
    #{name => grid, type => brick_grid}
  ]
}.

brick_class_methods >> init
| Self Args Self |
call_next_method Self Args Self,
get Self target Target,
new observable_list [] Sources,
new observable_list [] Rows,
set_slots Self #{
  sources => Sources,
  rows => Rows,
  package_options => [],
  edits => [],
  focus => #{}
},
new method_filters #{target => Target, subscriber => Self} Filters,
set_slot Self filters Filters,
make_grid Self Grid,
set_slot Self grid Grid,
refresh Self.

brick_class_methods >> refresh
| Self |
get_slots Self #{
  target => Target,
  filters => FilterModels,
  sources => Sources,
  rows => Rows
},
get FilterModels contents Filters,
findall Entry Entries {
  method_source Target _Method Source Side,
  put Source side Side Candidate,
  forall {member Filters Filter} {accepts Filter Candidate},
  = Entry #{source => Source, scope => #{text => Side}}
},
lambda [Entry, Row] Make {
  get_slots Entry #{source => Source, scope => Scope},
  edit_for Self Source Edit,
  get Source target Method,
  = Row #{
    edit => Edit,
    scope => Scope,
    target => Method
  }
},
map Entries Make Items,
lambda [Entry, Source] Record (get Entry source Source),
map Entries Record Records,
get Sources contents Records -> pass ; replace Sources Records,
get Rows contents Items -> pass ; replace Rows Items,
get Self focus Focus,
member Items Focus -> pass ; set_slot Self focus #{}.

brick_class_methods >> navigate
| Self Edit Step |
adjacent Self Edit Step Row -> set_slot Self focus Row ; pass.

brick_class_methods >> adjacent
| Self Edit Step Row |
get Self rows Rows,
get Rows contents Items,
at Items Index Current,
get Current edit Edit,
= Next (+ Index Step),
>= Next 0,
at Items Next Row.

brick_class_methods >> to_xaml
| Self Text |
get Self grid Grid,
to_xaml Grid Text.

brick_class_methods >> make_grid
| Self Grid |
get Self filters Filters,
new brick_slot_binding #{object_id => Self, path => filters} Binding,
bar_brick Filters Binding Bar,
new brick_slot_binding #{object_id => Self, path => rows} Items,
new brick_slot_binding #{object_id => Self, path => focus} Focus,
selection_styles Self Styles,
new brick_stack_panel #{} RowPanel,
new brick_table #{
  background => "Transparent",
  auto_scroll_to_selected_item => false,
  bring_into_view_on_focus_change => false,
  border_thickness => "0",
  columns => [#{cell => brick_method_snippet, width => "*"}],
  grid_row => 1,
  items_panel => RowPanel,
  items_source => Items,
  row_spacing => 2,
  navigation_item => Focus,
  show_headers => false,
  styles => Styles
} Methods,
new brick_row_definition #{height => "Auto"} HeaderRow,
new brick_row_definition #{height => "*"} MethodsRow,
new brick_grid #{children => [Bar, Methods], row_definitions => [HeaderRow, MethodsRow]} Grid.

brick_class_methods >> edit_for
| Self Source Edit |
get Source target Target,
get Self edits Edits,
{member Edits Existing, get Existing source_record Previous, get Previous target Target} -> {
  = Edit Existing,
  refresh Edit Source
} ; {
  new method_source_edit #{source_record => Source, methods_view => Self} Edit,
  set_slot Self edits [Edit . Edits]
}.

brick_class_methods >> selection_styles
| _Self Styles |
new brick_setter #{property => "Background", value => "Transparent"} Background,
lambda [Selector, Style] Make (new brick_style #{selector => Selector, setters => [Background]} Style),
map [
  "TableViewRow:pointerover /template/ Border#Border",
  "TableViewRow:pressed /template/ Border#Border",
  "TableViewRow:selected /template/ Border#Border",
  "TableViewRow:selected:pointerover /template/ Border#Border",
  "TableViewRow:selected:pressed /template/ Border#Border"
] Make Styles.

brick_class_methods >> package_options
| Self Source Options |
get Source owner Owner,
get Self package_options Choices,
{member Choices Choice, get_slots Choice #{owner => Owner, options => Options}} -> pass ; {
  findall Entry Entries {
    package_candidate Source Package,
    = Entry #{text => Package, target => Package}
  },
  new observable_list Entries Options,
  set_slot Self package_options [#{owner => Owner, options => Options} . Choices]
}.