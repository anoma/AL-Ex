# Competing package providers

`stable/` and `experimental/` are independent channel roots. Each channel
offers providers for the same three package classes.

| Package | Provider source | Dependency effect |
| --- | --- | --- |
| `:greeting` | Different in each channel | Produces a different build and behaviour |
| `:punctuation` | Identical in both channels | Reuses the same build |
| `:welcome` | Identical in both channels | Produces a different build because its selected Greeting build changes |

With Stable first, an activated Welcome object answers `[:hello, :bang]`.
With Experimental first, it answers `[:howdy, :bang]`.

The two channel offerings always remain distinct durable provider objects. Build
reuse depends on provider source and exact dependency builds rather than channel
identity.

Run the complete example through
`Examples.ALPackages.channels_offer_providers_and_builds_track_dependency_choices/0`.
