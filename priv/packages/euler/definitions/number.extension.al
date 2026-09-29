number >> euler_1
| N Sum |
findall Candidate Candidates {
  Candidate < N,
  Candidate > 0,
  Candidate = X * 5 or Candidate = X * 3,
  label Candidate
},
sum Candidates Sum.