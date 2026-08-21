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
import pathlib
import sys
from collections import Counter
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "input",
        type=pathlib.Path,
        help="JSON output from `goalong-history-query computer-history YYYY-MM-DD`.",
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


def provenance_is_nonempty(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    return any(
        isinstance(value.get(key), list) and bool(value[key])
        for key in ("sourceEventIDs", "sourceSequences", "sourceEventHashes")
    )


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

    try:
        payload = json.loads(args.input.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Could not read {args.input}: {exc}", file=sys.stderr)
        return 66

    errors: list[str] = []
    envelope = as_dict(payload, "root", errors)
    memory = envelope.get("memory")
    if memory is None:
        error = envelope.get("error") or "memory is null"
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

    if positive_int(resource_count) and resource_count != len(resources):
        fail(
            errors,
            f"coverage.resourceCount={resource_count} but resources={len(resources)}",
        )
    if positive_int(episode_count) and episode_count != len(episodes):
        fail(
            errors,
            f"coverage.episodeCount={episode_count} but episodes={len(episodes)}",
        )
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
    preceding_end: str | None = None
    for episode_index, raw_episode in enumerate(episodes):
        episode = as_dict(raw_episode, f"episodes[{episode_index}]", errors)
        if not provenance_is_nonempty(episode.get("provenance")):
            fail(errors, f"episodes[{episode_index}] has empty provenance")
        start = episode.get("start")
        end = episode.get("end")
        if not isinstance(start, str) or not isinstance(end, str):
            fail(errors, f"episodes[{episode_index}] start/end must be ISO strings")
        elif start > end:
            fail(errors, f"episodes[{episode_index}] ends before it starts")
        if preceding_end is not None and isinstance(start, str) and start < preceding_end:
            fail(errors, "episodes are not chronologically ordered")
        if isinstance(end, str):
            preceding_end = end

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
        last_interaction_start: str | None = None
        for interaction_index, raw_interaction in enumerate(interactions):
            interaction = as_dict(
                raw_interaction,
                f"episodes[{episode_index}].interactions[{interaction_index}]",
                errors,
            )
            if not provenance_is_nonempty(interaction.get("provenance")):
                fail(
                    errors,
                    f"episodes[{episode_index}].interactions[{interaction_index}] has empty provenance",
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
                last_interaction_start is not None
                and isinstance(interaction_start, str)
                and interaction_start < last_interaction_start
            ):
                fail(errors, f"episodes[{episode_index}] interactions are unordered")
            if isinstance(interaction_start, str):
                last_interaction_start = interaction_start
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
    if positive_int(linked_interactions) and len(observed_interaction_ids) != linked_interactions:
        fail(
            errors,
            f"coverage.linkedInteractionCount={linked_interactions} but episode interactions={len(observed_interaction_ids)}",
        )

    for suggestion_index, raw_suggestion in enumerate(suggestions):
        suggestion = as_dict(raw_suggestion, f"suggestions[{suggestion_index}]", errors)
        workflow_id = suggestion.get("workflowID")
        if workflow_id is not None and workflow_id not in workflow_ids:
            fail(
                errors,
                f"suggestions[{suggestion_index}] references unknown workflow {workflow_id!r}",
            )
        for episode_id in as_list(
            suggestion.get("episodeIDs"),
            f"suggestions[{suggestion_index}].episodeIDs",
            errors,
        ):
            if episode_id not in episode_ids:
                fail(
                    errors,
                    f"suggestions[{suggestion_index}] references unknown episode {episode_id!r}",
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
                "episodes": len(episodes),
                "resources": len(resources),
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
