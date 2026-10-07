number >> euler_1
| N Sum |
findall Candidate Candidates {
  < Candidate N,
  > Candidate 0,
  or (= Candidate (* X 5)) (= Candidate (* X 3)),
  label Candidate
},
sum Candidates Sum.
