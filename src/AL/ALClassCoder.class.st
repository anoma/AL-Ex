Class {
	#name : 'ALClassCoder',
	#superclass : 'Object',
	#instVars : [
		'object',
		'application',
		'moduleName',
		'announcer'
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

{ #category : 'accessing' }
ALClassCoder >> announcer [
	^ announcer ifNil: [ announcer := Announcer new ]
]

{ #category : 'accessing' }
ALClassCoder >> application [
	^ application
]

{ #category : 'accessing' }
ALClassCoder >> editorSessionId [
	"No editor session yet: AL methods eval in the default bridge context."
	^ nil
]

{ #category : 'querying' }
ALClassCoder >> functionEntries [
	"One BeamFunctionEntry per clause across all my methods — fields name / seq /
	 source / arity / start. seq drives ordering and (later) reorder; start is
	 seq+1 so the coder treats clauses as having editable source."

	| elixir rows |
	elixir := 'o = ' , object resolve
			, '
oid = o.id
{:atomic, entries} = :mnesia.transaction(fn ->
  for {:method, _m, name, id} <- AL.Object.scan_method(oid, :"$n", :"$id"),
      {:oapply, _id, seq, h, b} <- AL.Object.scan_oapply(id, :"$seq", :"$h", :"$b") do
    [to_string(name), seq, AL.Source.defmethod_source(oid, name, h, b), length(h)]
  end
end)
entries'.
	rows := (application evaluateAndWait: elixir) asList.
	^ rows
		collect: [ :row | 
			BeamFunctionEntry
				fields: (Dictionary new
						at: 'name' put: (row itemAt: 0);
						at: 'seq' put: (row itemAt: 1);
						at: 'source' put: (row itemAt: 2);
						at: 'arity' put: (row itemAt: 3);
						at: 'start' put: (row itemAt: 1) + 1;
						at: 'kind' put: 'def';
						yourself) ]
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
