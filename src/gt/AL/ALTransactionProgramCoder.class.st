Class {
    #name : 'ALTransactionProgramCoder',
    #superclass : 'ALClassCoder',
    #category : 'AL',
    #package : 'AL'
}

{ #category : 'querying' }
ALTransactionProgramCoder >> sourceRows [
    ^ (self application evaluateAndWait: 'AL.TransactionProgram.source_rows(' , self object resolve , ')') asList
]
