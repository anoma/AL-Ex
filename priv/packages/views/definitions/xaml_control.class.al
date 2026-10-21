@xaml_control
#{super => xaml_slot}.

xaml_control >> to_xaml
  | Self Text |
slot_value Self Value,
to_xaml Value Text.
