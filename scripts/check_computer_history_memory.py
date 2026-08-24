#!/usr/bin/env python3
"""Validate invariants in `goalong-history-query computer-history` JSON output.

This checker never modifies the local history. It verifies internal consistency,
source provenance, chronological ordering, interaction preservation and optional
semantic before/after coverage. It does not claim human identity, attention,
productivity, or complete capture of the operating system.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import Counter
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "input",
        help="JSON output path, or '-' to read it ephemerally from standard input.",
    )
    parser.add_argument(
        "--require-semantic-pairs",
        action="store_true",
        help="Require at least one interaction with both before and after context.",
    )
    parser.add_argument(
        "--minimum-pair-ratio",
        type=float,
        default=None,
        help="Minimum fraction of linked interactions with both semantic states (0..1).",
    )
    parser.add_argument(
        "--require-resources",
        action="store_true",
        help="Require at least one resolved source resource.",
    )
    parser.add_argument(
        "--require-actions",
        action="store_true",
        help="Require at least one reconstructed action interaction.",
    )
    parser.add_argument(
        "--quiet-errors",
        action="store_true",
        help="Report only fixed error categories and counts; never source-derived details.",
    )
    parser.add_argument(
        "--max-input-bytes",
        type=int,
        default=64 * 1_024 * 1_024,
        help="Reject larger JSON before decoding (default: 64 MiB).",
    )
    return parser.parse_args()


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def as_dict(value: Any, label: str, errors: list[str]) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    fail(errors, f"{label} must be an object")
    return {}


def as_list(value: Any, label: str, errors: list[str]) -> list[Any]:
    if isinstance(value, list):
        return value
    fail(errors, f"{label} must be an array")
    return []


def positive_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def check_provenance(value: Any, label: str, errors: list[str]) -> None:
    if not isinstance(value, dict):
        fail(errors, f"{label} must be an object")
        return

    has_reference = False
    for key in ("sourceEventIDs", "sourceEventHashes"):
        references = value.get(key)
        if not isinstance(references, list):
            fail(errors, f"{label}.{key} must be an array")
            continue
        has_reference = has_reference or bool(references)
        for index, reference in enumerate(references):
            if not isinstance(reference, str) or not reference.strip():
                fail(
                    errors,
                    f"{label}.{key}[{index}] must be a non-empty string",
                )

    sequences = value.get("sourceSequences")
    if not isinstance(sequences, list):
        fail(errors, f"{label}.sourceSequences must be an array")
    else:
        has_reference = has_reference or bool(sequences)
        for index, sequence in enumerate(sequences):
            if not positive_int(sequence):
                fail(
                    errors,
                    f"{label}.sourceSequences[{index}] must be a non-negative integer",
                )

    if not has_reference:
        fail(errors, f"{label} must contain at least one source reference")


def check_unique_ids(
    rows: list[Any], label: str, errors: list[str]
) -> set[str]:
    ids: list[str] = []
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            fail(errors, f"{label}[{index}] must be an object")
            continue
        identifier = row.get("id")
        if not isinstance(identifier, str) or not identifier:
            fail(errors, f"{label}[{index}].id must be a non-empty string")
            continue
        ids.append(identifier)
    duplicates = sorted(key for key, count in Counter(ids).items() if count > 1)
    if duplicates:
        fail(errors, f"{label} contains duplicate IDs: {duplicates}")
    return set(ids)


def main() -> int:
    args = parse_args()
    if args.minimum_pair_ratio is not None and not 0 <= args.minimum_pair_ratio <= 1:
        print("--minimum-pair-ratio must be between 0 and 1", file=sys.stderr)
        return 64
    if args.max_input_bytes <= 0:
        print("--max-input-bytes must be greater than zero", file=sys.stderr)
        return 64

    try:
        if args.input == "-":
            raw = sys.stdin.buffer.read(args.max_input_bytes + 1)
        else:
            with open(args.input, "rb") as handle:
                raw = handle.read(args.max_input_bytes + 1)
        if len(raw) > args.max_input_bytes:
            raise ValueError("input exceeds byte bound")
        payload = json.loads(raw)
    except (OSError, ValueError) as exc:
        if args.quiet_errors:
            print("Computer History input could not be decoded", file=sys.stderr)
        else:
            print(f"Could not read {args.input}: {exc}", file=sys.stderr)
        return 66

    errors: list[str] = []
    envelope = as_dict(payload, "root", errors)
    memory = envelope.get("memory")
    if memory is None:
        error = envelope.get("error") or "memory is null"
        if args.quiet_errors:
            print("No causal memory was available", file=sys.stderr)
        else:
            print(f"No causal memory available: {error}", file=sys.stderr)
        return 65
    memory = as_dict(memory, "memory", errors)
    coverage = as_dict(memory.get("coverage"), "memory.coverage", errors)
    episodes = as_list(memory.get("episodes"), "memory.episodes", errors)
    resources = as_list(memory.get("resources"), "memory.resources", errors)
    suggestions = as_list(memory.get("suggestions"), "memory.suggestions", errors)
    workflows = as_list(
        memory.get("workflowPatterns"), "memory.workflowPatterns", errors
    )

    resource_ids = check_unique_ids(resources, "memory.resources", errors)
    episode_ids = check_unique_ids(episodes, "memory.episodes", errors)
    check_unique_ids(suggestions, "memory.suggestions", errors)
    workflow_ids = check_unique_ids(workflows, "memory.workflowPatterns", errors)

    linked_interactions = coverage.get("linkedInteractionCount")
    paired_interactions = coverage.get("interactionsWithBeforeAndAfterContext")
    action_events = coverage.get("actionEventCount")
    source_events = coverage.get("sourceEventCount")
    resource_count = coverage.get("resourceCount")
    episode_count = coverage.get("episodeCount")
    retained_episode_count = coverage.get("retainedEpisodeCount")
    retained_interaction_count = coverage.get("retainedInteractionCount")
    retained_resource_count = coverage.get("retainedResourceCount")
    suppressed_events = coverage.get("suppressedEventCount")

    for key, value in (
        ("sourceEventCount", source_events),
        ("actionEventCount", action_events),
        ("linkedInteractionCount", linked_interactions),
        ("interactionsWithBeforeAndAfterContext", paired_interactions),
        ("resourceCount", resource_count),
        ("episodeCount", episode_count),
        ("suppressedEventCount", suppressed_events),
    ):
        if not positive_int(value):
            fail(errors, f"memory.coverage.{key} must be a non-negative integer")

    for key, value in (
        ("retainedEpisodeCount", retained_episode_count),
        ("retainedInteractionCount", retained_interaction_count),
        ("retainedResourceCount", retained_resource_count),
    ):
        if value is not None and not positive_int(value):
            fail(errors, f"memory.coverage.{key} must be null or a non-negative integer")

    expected_resource_rows = (
        retained_resource_count
        if positive_int(retained_resource_count)
        else resource_count
    )
    if positive_int(expected_resource_rows) and expected_resource_rows != len(resources):
        fail(
            errors,
            f"retained resource count={expected_resource_rows} but resources={len(resources)}",
        )
    if (
        positive_int(retained_resource_count)
        and positive_int(resource_count)
        and retained_resource_count > resource_count
    ):
        fail(errors, "retainedResourceCount exceeds exact resourceCount")

    expected_episode_rows = (
        retained_episode_count
        if positive_int(retained_episode_count)
        else episode_count
    )
    if positive_int(expected_episode_rows) and expected_episode_rows != len(episodes):
        fail(
            errors,
            f"retained episode count={expected_episode_rows} but episodes={len(episodes)}",
        )
    if (
        positive_int(retained_episode_count)
        and positive_int(episode_count)
        and retained_episode_count > episode_count
    ):
        fail(errors, "retainedEpisodeCount exceeds exact episodeCount")
    if positive_int(paired_interactions) and positive_int(linked_interactions):
        if paired_interactions > linked_interactions:
            fail(errors, "semantic pair count exceeds linked interaction count")
    if positive_int(action_events) and positive_int(linked_interactions):
        if action_events != linked_interactions:
            fail(
                errors,
                "actionEventCount must equal linkedInteractionCount; an action was lost or duplicated",
            )
    if positive_int(source_events) and positive_int(action_events):
        if action_events > source_events:
            fail(errors, "actionEventCount exceeds sourceEventCount")

    observed_interaction_ids: list[str] = []
    preceding_start: str | None = None
    preceding_interaction_start: str | None = None

    for resource_index, raw_resource in enumerate(resources):
        resource = as_dict(raw_resource, f"resources[{resource_index}]", errors)
        check_provenance(
            resource.get("provenance"),
            f"resources[{resource_index}].provenance",
            errors,
        )

    for episode_index, raw_episode in enumerate(episodes):
        episode = as_dict(raw_episode, f"episodes[{episode_index}]", errors)
        check_provenance(
            episode.get("provenance"),
            f"episodes[{episode_index}].provenance",
            errors,
        )
        start = episode.get("start")
        end = episode.get("end")
        if not isinstance(start, str) or not isinstance(end, str):
            fail(errors, f"episodes[{episode_index}] start/end must be ISO strings")
        elif start > end:
            fail(errors, f"episodes[{episode_index}] ends before it starts")
        if preceding_start is not None and isinstance(start, str) and start < preceding_start:
            fail(errors, "episodes are not chronologically ordered")
        if isinstance(start, str):
            preceding_start = start

        episode_resources = as_list(
            episode.get("resourceIDs"), f"episodes[{episode_index}].resourceIDs", errors
        )
        for resource_id in episode_resources:
            if resource_id not in resource_ids:
                fail(
                    errors,
                    f"episodes[{episode_index}] references unknown resource {resource_id!r}",
                )

        interactions = as_list(
            episode.get("interactions"),
            f"episodes[{episode_index}].interactions",
            errors,
        )
        local_ids = check_unique_ids(
            interactions, f"episodes[{episode_index}].interactions", errors
        )
        observed_interaction_ids.extend(local_ids)
        source_interaction_count = episode.get("sourceInteractionCount")
        if source_interaction_count is not None:
            if not positive_int(source_interaction_count):
                fail(
                    errors,
                    f"episodes[{episode_index}].sourceInteractionCount must be null or a non-negative integer",
                )
            elif source_interaction_count < len(interactions):
                fail(
                    errors,
                    f"episodes[{episode_index}].sourceInteractionCount is smaller than retained interactions",
                )
        for interaction_index, raw_interaction in enumerate(interactions):
            interaction = as_dict(
                raw_interaction,
                f"episodes[{episode_index}].interactions[{interaction_index}]",
                errors,
            )
            interaction_label = (
                f"episodes[{episode_index}].interactions[{interaction_index}]"
            )
            check_provenance(
                interaction.get("provenance"),
                f"{interaction_label}.provenance",
                errors,
            )
            interaction_start = interaction.get("start")
            interaction_end = interaction.get("end")
            if not isinstance(interaction_start, str) or not isinstance(
                interaction_end, str
            ):
                fail(
                    errors,
                    f"episodes[{episode_index}].interactions[{interaction_index}] start/end must be ISO strings",
                )
            elif interaction_start > interaction_end:
                fail(
                    errors,
                    f"episodes[{episode_index}].interactions[{interaction_index}] ends before it starts",
                )
            if (
                preceding_interaction_start is not None
                and isinstance(interaction_start, str)
                and interaction_start < preceding_interaction_start
            ):
                fail(errors, "interactions are not globally chronologically ordered")
            if isinstance(interaction_start, str):
                preceding_interaction_start = interaction_start
            for resource_id in as_list(
                interaction.get("resourceIDs"),
                f"episodes[{episode_index}].interactions[{interaction_index}].resourceIDs",
                errors,
            ):
                if resource_id not in resource_ids:
                    fail(
                        errors,
                        f"interaction references unknown resource {resource_id!r}",
                    )

    duplicate_interactions = sorted(
        identifier
        for identifier, count in Counter(observed_interaction_ids).items()
        if count > 1
    )
    if duplicate_interactions:
        fail(
            errors,
            f"interactions appear in multiple episodes: {duplicate_interactions}",
        )
    expected_interaction_rows = (
        retained_interaction_count
        if positive_int(retained_interaction_count)
        else linked_interactions
    )
    if positive_int(expected_interaction_rows) and len(observed_interaction_ids) != expected_interaction_rows:
        fail(
            errors,
            f"retained interaction count={expected_interaction_rows} but episode interactions={len(observed_interaction_ids)}",
        )
    if (
        positive_int(retained_interaction_count)
        and positive_int(linked_interactions)
        and retained_interaction_count > linked_interactions
    ):
        fail(errors, "retainedInteractionCount exceeds exact linkedInteractionCount")

    workflow_episode_ids: dict[str, set[str]] = {}
    for workflow_index, raw_workflow in enumerate(workflows):
        workflow = as_dict(
            raw_workflow, f"workflowPatterns[{workflow_index}]", errors
        )
        fingerprint = workflow.get("fingerprint")
        if not isinstance(fingerprint, str) or not fingerprint.strip():
            fail(
                errors,
                f"workflowPatterns[{workflow_index}].fingerprint must be a non-empty string",
            )
        occurrence_count = workflow.get("occurrenceCount")
        if not positive_int(occurrence_count) or occurrence_count < 2:
            fail(
                errors,
                f"workflowPatterns[{workflow_index}].occurrenceCount must be an integer of at least 2",
            )
        referenced_episode_ids = as_list(
            workflow.get("episodeIDs"),
            f"workflowPatterns[{workflow_index}].episodeIDs",
            errors,
        )
        valid_references: list[str] = []
        for reference_index, episode_id in enumerate(referenced_episode_ids):
            if not isinstance(episode_id, str) or not episode_id:
                fail(
                    errors,
                    f"workflowPatterns[{workflow_index}].episodeIDs[{reference_index}] must be a non-empty string",
                )
                continue
            valid_references.append(episode_id)
            if episode_id not in episode_ids:
                fail(
                    errors,
                    f"workflowPatterns[{workflow_index}] references unknown episode {episode_id!r}",
                )
        duplicate_references = sorted(
            episode_id
            for episode_id, count in Counter(valid_references).items()
            if count > 1
        )
        if duplicate_references:
            fail(
                errors,
                f"workflowPatterns[{workflow_index}].episodeIDs contains duplicate IDs: {duplicate_references}",
            )
        if positive_int(occurrence_count) and occurrence_count < len(
            set(valid_references)
        ):
            fail(
                errors,
                f"workflowPatterns[{workflow_index}].occurrenceCount is smaller than its current episode references",
            )
        workflow_id = workflow.get("id")
        if isinstance(workflow_id, str) and workflow_id:
            workflow_episode_ids[workflow_id] = set(valid_references)

    for suggestion_index, raw_suggestion in enumerate(suggestions):
        suggestion = as_dict(raw_suggestion, f"suggestions[{suggestion_index}]", errors)
        workflow_id = suggestion.get("workflowID")
        if workflow_id is not None and workflow_id not in workflow_ids:
            fail(
                errors,
                f"suggestions[{suggestion_index}] references unknown workflow {workflow_id!r}",
            )
        suggestion_episode_ids = as_list(
            suggestion.get("episodeIDs"),
            f"suggestions[{suggestion_index}].episodeIDs",
            errors,
        )
        valid_suggestion_episode_ids: list[str] = []
        for reference_index, episode_id in enumerate(suggestion_episode_ids):
            if not isinstance(episode_id, str) or not episode_id:
                fail(
                    errors,
                    f"suggestions[{suggestion_index}].episodeIDs[{reference_index}] must be a non-empty string",
                )
                continue
            valid_suggestion_episode_ids.append(episode_id)
            if episode_id not in episode_ids:
                fail(
                    errors,
                    f"suggestions[{suggestion_index}] references unknown episode {episode_id!r}",
                )
        duplicate_suggestion_references = sorted(
            episode_id
            for episode_id, count in Counter(valid_suggestion_episode_ids).items()
            if count > 1
        )
        if duplicate_suggestion_references:
            fail(
                errors,
                f"suggestions[{suggestion_index}].episodeIDs contains duplicate IDs: {duplicate_suggestion_references}",
            )
        if (
            isinstance(workflow_id, str)
            and workflow_id in workflow_episode_ids
            and not set(valid_suggestion_episode_ids).issubset(
                workflow_episode_ids[workflow_id]
            )
        ):
            fail(
                errors,
                f"suggestions[{suggestion_index}].episodeIDs must be a subset of its workflow episode references",
            )

    if args.require_actions and linked_interactions == 0:
        fail(errors, "no reconstructed action interaction was available")
    if args.require_resources and not resources:
        fail(errors, "no source resource was resolved")
    if args.require_semantic_pairs and paired_interactions == 0:
        fail(errors, "no before/after semantic pair was available")
    if (
        args.minimum_pair_ratio is not None
        and positive_int(linked_interactions)
        and linked_interactions > 0
        and positive_int(paired_interactions)
    ):
        ratio = paired_interactions / linked_interactions
        if math.isfinite(ratio) and ratio < args.minimum_pair_ratio:
            fail(
                errors,
                f"semantic pair ratio {ratio:.3f} is below {args.minimum_pair_ratio:.3f}",
            )

    if errors:
        if args.quiet_errors:
            print(
                f"Computer History memory validation failed: {len(errors)} invariant violation(s)",
                file=sys.stderr,
            )
        else:
            print("Computer History memory validation FAILED", file=sys.stderr)
            for error in errors:
                print(f"- {error}", file=sys.stderr)
        return 1

    ratio_text = "n/a"
    if linked_interactions:
        ratio_text = f"{paired_interactions / linked_interactions:.1%}"
    print(
        json.dumps(
            {
                "valid": True,
                "source_events": source_events,
                "actions": action_events,
                "interactions": linked_interactions,
                "semantic_pairs": paired_interactions,
                "semantic_pair_ratio": ratio_text,
                "episodes": episode_count,
                "retained_episodes": len(episodes),
                "resources": resource_count,
                "retained_resources": len(resources),
                "retained_interactions": len(observed_interaction_ids),
                "workflows": len(workflows),
                "suggestions": len(suggestions),
                "suppressed_events": suppressed_events,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
