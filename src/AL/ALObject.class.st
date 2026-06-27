Class {
	#name : 'ALObject',
	#superclass : 'BeamProxyObject',
	#category : 'AL',
	#package : 'AL'
}

{ #category : 'dispatch' }
ALObject class >> elixirClass [
	^ 'AL.Object'
]

{ #category : 'gt-extensions' }
ALObject >> gtMethodsFor: aView [
	"I show each of my methods as a syntax-highlighted, editable Elixir coder,
	 source decompiled from the stored clauses by AL.Source."
	<gtView>
	<gtBeamView>
	^ aView explicit
		title: 'Methods';
		priority: 9;
		stencil: [
			| container |
			container := BlElement new
				layout: BlLinearLayout vertical;
				constraintsDo: [ :c | c horizontal matchParent. c vertical fitContent ];
				padding: (BlInsets all: 5);
				yourself.
			self methodSources do: [ :pair |
				| coder vm el |
				coder := GtElixirCoderModel new
					elixirLinkApplicationStrategy: LeElixirApplicationStrategy new;
					sourceCode: (GtCoderExplicitStringSource new source: (pair itemAt: 1));
					yourself.
				vm := coder asCoderViewModel.
				vm expanded: true.
				el := vm asElement.
				el constraintsDo: [ :c2 | c2 horizontal matchParent. c2 vertical fitContent ].
				container addChild: el ].
			container ]
]

{ #category : 'querying' }
ALObject >> methodSources [
	"I return [name, defmethod-source] pairs for my methods — decompiled by
	 AL.Source.method_sources/2 on the Elixir side."
	^ (self application evaluateAndWait: 'AL.Source.method_sources((' , self resolve , ').id)') asList
]
