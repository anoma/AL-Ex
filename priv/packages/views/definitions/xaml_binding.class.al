@xaml_binding
#{super => xaml_slot}.

xaml_binding >> to_xaml
  | Self Text |
get_slots Self #{owner => Owner, spec => Spec},
get_slots Spec #{name => Slot},
atom_string Slot RawPath,
atom_string Owner RawId,
xml_escape Self RawPath Path,
xml_escape Self RawId Id,
format "<al:BindExtension Path=\"~a\" ObjectId=\"~a\"/>" [Path, Id] Text.
