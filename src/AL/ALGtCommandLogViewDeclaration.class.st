Class {
	#name : 'ALGtCommandLogViewDeclaration',
	#superclass : 'GtBeamViewDeclaration',
	#category : 'AL',
	#package : 'AL'
}

{ #category : 'accessing' }
ALGtCommandLogViewDeclaration class >> remoteName [
	^ 'ALCommandLogViewSpecification'
]

{ #category : 'accessing' }
ALGtCommandLogViewDeclaration >> viewName [
	^ #columnedList
]

{ #category : 'view' }
ALGtCommandLogViewDeclaration >> treatView: view [
	| formattedItems rawItems colors colorMap textMap |
	formattedItems := (self rawData attributeAt: #items) asList.
	rawItems := (self rawData attributeAt: #rawItems) asList.
	colors := (self rawData attributeAt: #colors) asList.
	textMap := IdentityDictionary new: rawItems size.
	colorMap := IdentityDictionary new: rawItems size.
	rawItems withIndexDo: [ :item :idx |
		textMap at: item put: (formattedItems at: idx).
		colorMap at: item put: (colors at: idx) ].
	view items: [ rawItems ].

	(self rawData attributeAt: #columns) asList
		withIndexDo: [ :aColumn :anIndex |
			| title textBlock width |
			title := aColumn attributeAt: #title.
			width := #(22 80 65) at: anIndex ifAbsent: [ 0 ].
			textBlock := [ :item |
				| text color |
				text := (textMap at: item) asList at: anIndex.
				color := colorMap at: item ifAbsent: [ nil ].
				(anIndex = 1 and: [ color notNil ])
					ifTrue: [ text asRopedText
						foreground: (Color fromHexString: color);
						background: (Color fromHexString: color) ]
					ifFalse: [ text ] ].
			width > 0
				ifTrue: [ view column: title text: textBlock width: width ]
				ifFalse: [ view column: title text: textBlock ] ]
]
