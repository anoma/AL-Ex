Class {
	#name : 'ALClauseStreamingModel',
	#superclass : 'ElixirFunctionStreamingModel',
	#category : 'AL',
	#package : 'AL'
}

{ #category : 'streaming' }
ALClauseStreamingModel >> newCoderCacheKeyFor: anEntry [
	"Clauses of one method share name+arity, so the superclass's name/arity
	 key would collapse them into a single coder. I key on the clause seq —
	 its addressable position — to keep one coder per clause."
	^ (anEntry attributeAt: 'name') asString, '/', (anEntry attributeAt: 'seq') asString
]

{ #category : 'streaming' }
ALClauseStreamingModel >> newCoderFor: anEntry [
	"I build an ALClauseCoder (not an ElixirFunctionCoder) per stored clause,
	 propagating selfObject and my list (for future reordering)."
	| coder |
	coder := ALClauseCoder forEntry: anEntry moduleCoder: moduleCoder.
	coder selfObject: moduleCoder selfObject.
	coder list: self.
	^ coder
]
