Class {
    #name : 'ALPackageCoder',
    #superclass : 'ALClassCoder',
    #category : 'AL',
    #package : 'AL'
}

{ #category : 'querying' }
ALPackageCoder >> sourceRows [
    ^ (self application evaluateAndWait: 'AL.Package.source_rows(' , self object resolve , ')') asList
]
