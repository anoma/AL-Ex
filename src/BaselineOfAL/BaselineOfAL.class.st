"
Metacello baseline for the AL GToolkit tooling (package AL). Two load modes: `load` (fresh / CI) pulls + pins the BEAM bridge (Gt4beam v0.17.3, matching mix.lock) then AL; `load: #dev` loads only AL against an already-present, possibly work-in-progress gt4beam, so hacking the bridge never hits the pin.
"
Class {
	#name : 'BaselineOfAL',
	#superclass : 'BaselineOf',
	#category : 'BaselineOfAL',
	#package : 'BaselineOfAL'
}

{ #category : 'baseline' }
BaselineOfAL >> baseline: spec [
	<baseline>
	spec
		for: #common
		do: [ spec
				baseline: 'Gt4beam'
				with: [ spec repository: 'github://mariari/ElixirGtBridge:v0.17.3/src' ].
			spec package: 'AL'.	"`load: #dev` loads only AL against an already-present, possibly
		 work-in-progress gt4beam, so hacking the bridge never hits the pin."
			spec
				group: 'default' with: #('Gt4beam' 'AL');
				group: 'dev' with: #('AL') ]
]
