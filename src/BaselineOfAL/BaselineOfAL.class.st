Class {
	#name : 'BaselineOfAL',
	#superclass : 'BaselineOf',
	#category : 'BaselineOfAL',
	#package : 'BaselineOfAL'
}

{ #category : 'baseline' }
BaselineOfAL >> baseline: spec [
	<baseline>
		^ spec for: #common do: [
			spec package: 'AL'
		]
]
