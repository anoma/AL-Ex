Class {
	#name : 'ALClauseCoder',
	#superclass : 'ElixirFunctionCoder',
	#instVars : [
		'seq'
	],
	#category : 'AL',
	#package : 'AL'
}

{ #category : 'add-ons' }
ALClauseCoder >> addDeleteAddOnsTo: anAddOns to: aViewModel from: aCoderModel [
	"Deleting a clause is a store retract, not a file splice. Deferred (read-only cut)."
]

{ #category : 'add-ons' }
ALClauseCoder >> addHelpAddOnsTo: anAddOns to: aViewModel from: aCoderModel [
	"No GtBridge.Documentation for an AL clause. No Help action (read-only cut)."
]

{ #category : 'add-ons' }
ALClauseCoder >> addMoveAddOnsTo: anAddOns to: aViewModel from: aCoderModel [
	"Reordering swaps my clause seq with a neighbour's and re-stores both
	 the next increment; suppressed in this read-only cut."
]

{ #category : 'add-ons' }
ALClauseCoder >> addRunAddOnsTo: anAddOns to: aViewModel from: aCoderModel [
	"AL clauses aren't callable Elixir functions. No Run action (read-only cut)."
]

{ #category : 'add-ons' }
ALClauseCoder >> addSaveAddOnsTo: anAddOns to: aViewModel from: aCoderModel [
	"Save-to-store (retract + set_oapply at my seq, through the interpreter so
	 it's logged) is the next increment. Suppressed in this read-only cut."
]

{ #category : 'navigation' }
ALClauseCoder >> contextModuleName [
	"AL clauses have no backing Elixir module. my owner's moduleName is the
	 inspected class atom (I.E. list). Returning it would make the
	 expander styler emit `GtBridge.Analysis.call_sites(..., list)`. 
	 nil tells the styler (and alias resolution) to skip module context."

	^ nil
]

{ #category : 'initialization' }
ALClauseCoder >> initializeFromEntry: anEntry moduleCoder: anElixirModuleCoder [
	"No recompilation to subscribe to currently, change later"

	moduleCoder := anElixirModuleCoder.
	self refreshFromEntry: anEntry
]

{ #category : 'actions' }
ALClauseCoder >> moveBy: anOffset [
	"Defensive noop for this readonly cut. Reordering swaps my clause seq
	 with a neighbour's and re-stores both through the interpreter."

	Transcript
		show: 'ALClauseCoder: move not yet wired (clause seq ' , seq printString , ')';
		cr
]

{ #category : 'initialization' }
ALClauseCoder >> refreshFromEntry: anEntry [
	"I additionally capture the clause `seq`. The rest (name/arity/source/
	 startLine) is loaded by my superclass; our entry's #start is seq + 1 so
	 hasSource is true and the source renders."
	super refreshFromEntry: anEntry.
	seq := anEntry attributeAt: 'seq'
]

{ #category : 'actions' }
ALClauseCoder >> saveFunction [
	"Defensive noop for this readonly cut: the C-s shortcut is still
	 wired, but persisting an edited clause (retract + set_oapply at my seq,
	 through the interpreter so it's logged) is the next increment."

	Transcript
		show: 'ALClauseCoder: save not yet wired (clause seq ' , seq printString , ')';
		cr
]

{ #category : 'accessing' }
ALClauseCoder >> seq [
	"My addressable position in my method's ordered clause list. The key
	 save/move will target in the AL oapply store."

	^ seq
]
