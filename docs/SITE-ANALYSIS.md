---
context_room:
  id: goalong.history.selected-site-analysis
---

# Analyse a selected website request

## Summary

Goalong History can analyse one JSON request explicitly selected from the website using a separate local ChatGPT connection. The result stays an editable text draft until the user exports it and chooses to import it on the website.

## Defines

The selected-file analysis journey, its data boundary and failure behavior.

## Does not define

Automatic daily analysis, website sharing permissions, OpenRouter billing or the website upload-token protocol.

## Use the feature

1. On the website, choose a day and the fields to analyse, review them, and download the ChatGPT request JSON.
2. In Goalong History, open **Settings → Goalong website → Analyser une demande du site**. Enable the optional **ChatGPT analysis** capability if it is off.
3. Use **Choisir la demande…** to select that JSON file. Read the date, timezone and exact data preview.
4. Use **Se connecter à ChatGPT** and complete the official account login. Codex must be installed and support the required restricted analysis settings and model.
5. Check the consent for the displayed data, then choose **Analyser avec ChatGPT**. Review and edit the title, summary and outcomes.
6. Export the reviewed draft, then import that file on the website when ready. Exporting does not send it to the website. **Se déconnecter** ends this feature's ChatGPT connection.

If the file is not visible in the macOS chooser, use **⌘⇧G** to enter its exact path. Invalid, changed, oversized or unsupported requests are rejected with an actionable message. The file is limited to 256 KiB and one day.

## Data and connection boundary

This flow reads the selected file only. It does not build a daily context from native archives or read provider conversations. Its request is treated as data rather than instructions. The separate `site-analysis-codex-home` profile does not copy the user's existing Codex credentials. The local Codex client owns the authenticated ChatGPT transport.

The client requires a temporary analysis thread, a restricted permission profile and an empty temporary workspace. It verifies the settings returned by Codex and stops on unexpected capabilities or tool use. An unavailable model or incompatible Codex version produces an error; there is no silent model fallback.

The draft can contain only a title, summary and outcomes. It cannot replace measured durations or grant a verified badge. Export writes only the chosen output file with mode `0600`; it does not change the Downloads folder's permissions. Website copies and audiences remain governed by the website's import and sharing controls.

Turning off the capability cancels an active operation. Closing the sheet discards its transient state; an explicitly exported file remains on disk. The login profile is separate from the website session and the normal Codex application.

## Implementation and verification

The [native sheet](../Sources/LocalHistoryApp/GoalongSiteAnalysisSheet.swift), [request and draft contracts](../Sources/LocalHistoryCore/GoalongSiteAnalysis.swift), and [Codex bridge](../Sources/LocalHistoryApp/ChatGPT/CodexAppServerClient.swift) own the exact behavior. The [core tests](../Tests/LocalHistoryCoreTests/GoalongSiteAnalysisTests.swift) and [client tests](../Tests/LocalHistoryAppTests/SelectedSiteAnalysisTests.swift) cover validation, confinement, consent, protocol checks and output boundaries.

During the 8 September 2026 release checks, the production sheet was exercised in an isolated preview with a synthetic request: native file selection, exact preview, consent, authenticated ChatGPT generation, draft editing, protected export and logout succeeded. The combined build was also installed separately on the owner's Mac, with history, source permissions and real input callbacks preserved. Those observations do not establish a notarized public package or a direct website upload from the native token picker.
