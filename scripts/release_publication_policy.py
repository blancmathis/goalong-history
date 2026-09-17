"""A passed official build may be promoted only when its exact commit is current main."""
import re

def validate_staging_run(run: dict, current_main: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{40}", current_main):
        raise ValueError("Expected the complete current main commit")
    if run.get("conclusion") != "success":
        raise ValueError("The entire input workflow must succeed first")
    if run.get("headSha") != current_main:
        raise ValueError("The signing input must match the exact current main commit")
    if run.get("workflowName") not in {
        "Continuous Community macOS release", "Prepare universal archive for local signing"
    }:
        raise ValueError("Unexpected signing-input workflow")
    # The caller reads this run and artifact from the fixed official repository.
    # A branch name is not an authenticity check: an unchanged, tested release
    # candidate remains the same commit after its fast-forward promotion to main.
