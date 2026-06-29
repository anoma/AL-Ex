Class {
	#name : 'BaselineOfAL',
	#superclass : 'BaselineOf',
	#category : 'BaselineOfAL',
	#package : 'BaselineOfAL'
}

{ #category : 'baseline' }
BaselineOfAL >> baseline: spec [
	<baseline>
	^ spec
		for: #common
		do: [ spec
				baseline: 'Gt4beam'
				with: [ spec repository: 'github://mariari/ElixirGtBridge:v0.17.3/src' ].
			spec package: 'AL' with: [ spec requires: #('Gt4beam') ] ]
]
