# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

Goalong History is for a person reviewing activity from devices and local agent tools they own and use themselves. The core job is to understand how a day was spent without handing a second copy of private history to the app.

## Product Purpose

Goalong History records and combines local computer activity, imported Apple Screen Time, and directly read AI-conversation metadata. It should make a day inspectable, verifiable, and useful to a user or an explicitly chosen agent while keeping capture efficient and local-first.

## Positioning

The product separates evidence capture from interpretation: source activity remains local and directly readable, while optional AI analysis produces only a small derived daily report.

## Operating Context

The macOS app runs throughout the day, records foreground activity, imports Screen Time exports for Apple devices, indexes configured local AI-conversation sources without copying transcripts, and lets the user inspect or selectively share the resulting evidence.

## Capabilities and Constraints

- Computer History is factual and grouped into ten-minute windows.
- AI-conversation transcripts are read on demand from their original source and are never copied into Goalong History storage.
- A daily Activity report may combine Computer History, Screen Time, and AI-conversation evidence.
- AI analysis is optional and currently uses the user's connected ChatGPT/Codex account. OpenRouter remains a future provider.
- The requested analysis model is `gpt-5.6-luna` with `high` reasoning effort; the app must fail clearly instead of silently choosing another model.
- A daily report is persisted as a bounded derived artifact, not as a second activity or transcript archive.
- Missing, inaccessible, excluded, or incomplete evidence must remain visible as a coverage limitation and must not be treated as proof of inactivity.
- Goalong History must minimize background processes, memory, storage, repeated scans, and token use.

## Evidence on Hand

The repository contains the native SwiftUI app, local activity stores, Apple Screen Time import, direct-source Agent Activity adapters, ChatGPT/Codex account integration, tests, privacy audits, build scripts, and installation workflow.

## Product Principles

- Preserve source truth and label coverage gaps.
- Store the smallest useful derived representation.
- Keep interpretation optional, inspectable, and replaceable.
- Prefer bounded incremental work over repeated full scans.
- Judge observable work patterns, never a person's worth or intent.

## Accessibility & Inclusion

Important state, score, confidence, and coverage must not rely on color alone. Controls require clear labels, keyboard access, and readable loading, empty, and error states.
