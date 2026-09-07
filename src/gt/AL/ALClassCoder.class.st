Class {
	#name : 'ALClassCoder',
	#superclass : 'Object',
	#instVars : [
		'object',
		'application',
		'moduleName',
		'announcer',
		'functionStreamingModel'
	],
	#category : 'AL',
	#package : 'AL'
}

{ #category : 'instance creation' }
ALClassCoder class >> forObject: anALObject [
	"I am the moduleCoder analog for an AL class, built from its ALObject proxy."

	^ self new
		setObject: anALObject;
		yourself
]

{ #category : 'announcing' }
ALClassCoder >> announce: anAnnouncement [
	"The streaming model announces its range through its module coder."

	^ self announcer announce: anAnnouncement
]

{ #category : 'accessing' }
ALClassCoder >> announcer [
	^ announcer ifNil: [ announcer := Announcer new ]
]

{ #category : 'accessing' }
ALClassCoder >> application [
	^ application
]

{ #category : 'accessing' }
ALClassCoder >> coderRangeUpTo: aModuleName [
	"An AL class has neither namespace ancestors nor imports, so the range the
	 streaming model widens over is always just me."

	^ OrderedCollection with: self
]

{ #category : 'accessing' }
ALClassCoder >> editorSessionId [
	"No editor session yet: AL methods eval in the default bridge context."
	^ nil
]

{ #category : 'querying' }
ALClassCoder >> functionEntries [
	| rows |
	rows := self sourceRows.
	^ rows
		collect: [ :row | 
			BeamFunctionEntry
				fields: (Dictionary new
						at: 'name' put: (row itemAt: 0);
						at: 'seq' put: (row itemAt: 1);
						at: 'source' put: (row itemAt: 2);
						at: 'arity' put: (row itemAt: 3);
						at: 'start' put: (row itemAt: 4);
						at: 'kind' put: 'def';
						yourself) ]
]

{ #category : 'accessing' }
ALClassCoder >> functionStreamingModel [
	"The model that streams my clauses; the substring highlight styler reaches
	 its active filters through me."

	^ functionStreamingModel
]

{ #category : 'accessing' }
ALClassCoder >> functionStreamingModel: anElixirFunctionStreamingModel [
	functionStreamingModel := anElixirFunctionStreamingModel
]

{ #category : 'gt-extensions' }
ALClassCoder >> gtClausesFor: aView [
	"I render each stored clause of my object's methods as a folded,
	 syntax-highlighted Elixir coder. One ALClauseCoder per clause,
	 addressable by seq,reusing gt4beam's folded streaming list (the same
	 element ElixirModuleCoder uses for its Functions tab)."

	<gtView>
	^ aView explicit
		title: 'Clauses';
		priority: 8;
		stencil: [ | streaming vm container |
			streaming := ALClauseStreamingModel forModuleCoder: self.
			vm := ElixirFoldedCodersViewModel new
					streamingCodersModel: streaming;
					yourself.
			container := BlElement new
					layout: BlLinearLayout vertical;
					constraintsDo: [ :c | 
						c horizontal matchParent.
						c vertical matchParent ];
					yourself.
			container
				addChild: (ElixirFunctionStreamingElement new
						streamingCodersViewModel: vm;
						yourself) matchParent.
			container ]
]

{ #category : 'accessing' }
ALClassCoder >> moduleName [
	"The AL class name as a string: keys the per-module announcer."

	^ moduleName
]

{ #category : 'accessing' }
ALClassCoder >> object [
	^ object
]

{ #category : 'accessing' }
ALClassCoder >> selfObject [
	^ object
]

{ #category : 'initialization' }
ALClassCoder >> setObject: anALObject [
	object := anALObject.
	application := anALObject application.
	moduleName := anALObject application
			evaluateAndWait: 'to_string((' , anALObject resolve , ').id)'
]

{ #category : 'querying' }
ALClassCoder >> sourceRows [
    ^ (application evaluateAndWait: 'o = ' , object resolve , '; AL.Source.method_source_rows(o.id, AL.Object.branch_id(o))') asList
]
