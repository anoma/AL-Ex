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
	^ aView forward
		title: 'Methods';
		priority: 9;
		object: [ALClassCoder forObject: self];
		view: #gtClausesFor:
]

{ #category : 'querying' }
ALObject >> methodSources [
	"I return [name, defmethod-source] pairs for my methods — decompiled by
	 AL.Source.method_sources/2 on the Elixir side."
	^ (self application evaluateAndWait: 'AL.Source.method_sources((' , self resolve , ').id)') asList
]
