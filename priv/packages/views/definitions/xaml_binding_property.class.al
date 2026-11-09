@xaml_binding_property
#{super => xaml_property}.

xaml_binding_property >> xaml_content
| Self Value Text |
isa Value brick,
to_xaml Value Text.

xaml_binding_property >> xaml_content
| Self Value Text |
not (isa Value brick),
get_slots Self #{owner => Owner, spec => Spec},
get_slots Spec #{name => Slot},
atom_string Slot RawPath,
atom_string Owner RawId,
xml_escape Self RawPath Path,
xml_escape Self RawId Id,
format "<al:BindExtension Path=\"~a\" ObjectId=\"~a\"/>" [Path, Id] Text.
