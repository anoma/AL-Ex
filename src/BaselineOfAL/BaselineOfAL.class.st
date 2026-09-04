"
Metacello baseline for the AL GToolkit tooling (package AL). Two load modes: `load` (fresh / CI) pulls + pins the BEAM bridge (matching mix.lock) then AL; `load: #dev` loads only AL against an already-present, possibly work-in-progress gt4beam, so hacking the bridge never hits the pin.
"
Class {
	#name : 'BaselineOfAL',
	#superclass : 'BaselineOf',
	#category : 'BaselineOfAL',
	#package : 'BaselineOfAL'
}

{ #category : 'loading' }
BaselineOfAL class >> loadLepiter [
	"Register the notebook bundled with the Iceberg checkout."
	^ IceRepository registry
		detect: [ :repository | repository name = 'AL-Ex' ]
		ifFound: [ :repository | self loadLepiterFrom: repository repositoryDirectory ]
		ifNone: [ self error: 'AL-Ex is not registered in Iceberg. Use BaselineOfAL loadLepiterFrom: yourCheckoutDirectory.' ]
]

{ #category : 'loading' }
BaselineOfAL class >> loadLepiterFrom: aDirectory [
	"Support local Tonel loads and checkouts with other directory names."
	| directory database |
	directory := aDirectory asFileReference / 'lepiter'.
	directory isDirectory
		ifFalse: [ self error: 'No lepiter directory in the supplied AL checkout.' ].
	database := LeDatabasesRegistry defaultLogicalDatabase.
	database properties addRegisteredDirectory: directory.
	LeJsonV4 cleanUp.
	database fullReload.
	^ database
]

{ #category : 'baseline' }
BaselineOfAL >> baseline: spec [
	<baseline>
	spec
		for: #common
		do: [ spec
				baseline: 'Gt4beam'
				with: [ spec repository: 'github://mariari/ElixirGtBridge:v0.20.1/src' ].
			spec package: 'AL'.	"`load: #dev` loads only AL against an already-present, possibly
		 work-in-progress gt4beam, so hacking the bridge never hits the pin."
			spec
				group: 'default' with: #('Gt4beam' 'AL');
				group: 'dev' with: #('AL') ]
]
