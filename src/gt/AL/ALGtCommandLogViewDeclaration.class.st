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
	"Rows are indices; a row's operation is fetched only when it is sent."
	| formattedItems colors rawItems |
	formattedItems := (self rawData attributeAt: #items) asList.
	colors := (self rawData attributeAt: #colors) asList.
	rawItems := self rawData attributeAt: #rawItems.
	view items: [ 1 to: formattedItems size ].
	view send: [ :index | rawItems itemAt: index - 1 ].

	(self rawData attributeAt: #columns) asList
		withIndexDo: [ :aColumn :anIndex |
			| title textBlock width |
			title := aColumn attributeAt: #title.
			width := #(22 80 65) at: anIndex ifAbsent: [ 0 ].
			textBlock := [ :index |
				| text color |
				text := (formattedItems at: index) asList at: anIndex.
				color := colors at: index.
				(anIndex = 1 and: [ color notNil ])
					ifTrue: [ text asRopedText
						foreground: (Color fromHexString: color);
						background: (Color fromHexString: color) ]
					ifFalse: [ text ] ].
			width > 0
				ifTrue: [ view column: title text: textBlock width: width ]
				ifFalse: [ view column: title text: textBlock ] ]
]
