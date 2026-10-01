# Separate source acceptance from native predeployment evidence

Status: accepted; native runtime acceptance of the changed source remains open.

There is no available root/systemd runner. Accept source using independent review,
pure Nix composition, builds and available ordinary native process/database/tool
checks. Do not introduce a VM, test host or privilege/credential/isolation workaround.
Keep native execution mandatory before deployment in the single joint
Apps/Reliability matrix in [Recovery](../recovery.md#acceptance-boundary); historical
VM results and theoretical flags do not establish runtime PASS for changed code.
This supersedes the earlier VM gate policy without discarding its historical evidence.

Publication commits by atomically selecting a complete export. Every precommit
failure preserves the old complete export; after commit, late failure or
cancellation never rolls back the new selection. Capture records prior activity
before mutation and refuses a new allocation while a full attempt is unresolved.
Reclaim only owned unselected data before the next allocation, never a selected
pending record. Normal deactivation keeps `current`. Reader copying finishes under
the publication lock before source reclaim; uploads keep independent disk copies.
The producer capacity bound includes transient/native workspace in two trees,
with reader copies added separately. This keeps ownership and failure boundaries
explicit without adding an executor or generation registry.

Before commit, native capture must succeed with the writer quiescent, descendants
gone and prior activity restored. Payload shape and ordered capture timestamps
must meet reader admission requirements. Completion is distinct from semantic
recovery: semantic database import remains in retained validation of independently
restored input. There is no precommit validator scratch tree. Account separately
for restored input, wrapper copy, writable database scratch and its overhead
alongside producer and reader trees; resource limits do not cap total file bytes.
