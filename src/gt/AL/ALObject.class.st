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

{ #category : 'printing' }
ALObject >> gtDisplayOn: aStream [
    aStream nextPutAll: self objectName
]

{ #category : 'gt-extensions' }
ALObject >> gtInspectorTitleString [
    ^ self objectTitle
]

{ #category : 'gt-extensions' }
ALObject >> gtRemoteInspectorContentFor: aView [
    ^ GtPhlowLabelledViewBuilder new
        object: self;
        view: aView;
        context: GtPhlowContext new;
        viewsSelector: #gtViewsForRemoteSideInContext:;
        titleComputation: [ self objectTitle ];
        build
]

{ #category : 'gt-extensions' }
ALObject >> objectTitle [
    ^ [ self application evaluateAndWait: 'AL.GtBridge.object_title(' , self resolve , ')' ]
        on: Error
        do: [ 'AL.Object' ]
]

{ #category : 'querying' }
ALObject >> objectName [
    ^ [ self application evaluateAndWait: 'AL.GtBridge.display_name(' , self resolve , ')' ]
        on: Error
        do: [ 'AL.Object' ]
]
