# Intake decisions

`Invoke-UpstreamIntake.ps1 -Action Record` writes one JSON record per evaluated
upstream commit here. Keep accepted, partially ported, skipped, and rejected
records: the absence of a downstream commit is not enough to distinguish a
deliberate skip from work that has not been examined.
