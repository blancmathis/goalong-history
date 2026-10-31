#!/usr/bin/env bash
# seed:controls-enabled (J-0788 J-0794 J-0874): enables the ChatGPT controls that are disabled without a connection. Env: HOME DATA. Exit 3 (consent read at launch).
# Persisted part = consent chatGPTAnalysis: it enables « Se connecter à ChatGPT » (GoalongSiteAnalysisSheet.swift:263 .disabled(!consents.isEnabled(.chatGPTAnalysis)), J-0874)
# and lets connect() run (:77). In-memory part = `connected` (:13): provided by the fake codex of chatgpt-connected (same file edits), then the nav clicks « Connecter ChatGPT ».
# « Analyser le contexte de cette session » (GoalongRhythmStudio.swift:166) also needs the toggle « J’autorise l’envoi… » (:165, @State model.consentToAnalyze): nav ck:.
# « Vous choisirez ensuite les champs… » (:199) is static text, always shown; « Utiliser cette session relue » beside it needs a result (model.result, :201) = needs a real analysis: not seedable.
exec bash "$(dirname "$0")/chatgpt-connected.sh" "$@"
