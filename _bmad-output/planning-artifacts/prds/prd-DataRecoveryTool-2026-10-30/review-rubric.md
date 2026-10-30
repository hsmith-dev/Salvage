# PRD Quality Review — Open-Source macOS Data Recovery Tool (OpenRecover)

## Overall verdict
This PRD has a clear, coherent thesis — verifiable trust over algorithmic superiority — that visibly drives feature prioritization (§4.6 Privacy & Transparency exists as its own feature, not an afterthought), success metrics, and counter-metrics (SM-C3 explicitly defends the thesis against adoption pressure). It's strong on decision-readiness, strategic coherence, and downstream usability. Its real weak point is done-ness clarity: the single FR carrying the most product risk (FR-12, recovery-confidence scoring — the thing SM-C1 exists specifically to guard) has no testable bound and is explicitly deferred to an open question, and roughly half the FRs are missing the testable-consequence pattern the document otherwise establishes well. A focused pass on FR-12/FR-19/FR-9 plus an Assumptions Index mechanical fix would bring this to green-light quality.

## Decision-readiness — strong
Decisions are stated as decisions, not hedged as "considerations" — Monetization and Platform in particular are unambiguous. Trade-offs are named with what was given up: Vision explicitly concedes "mature closed-source tools have a head start" on raw recovery quality rather than claiming superiority; FR-5's Out of Scope names NTFS/EXT/ReFS/UFS and says why (not needed for the macOS-native case). Open Questions read as genuinely open — §8 items 4, 6, 7, 8 have no answer smuggled into the next sentence. `[NOTE FOR PM]` callouts land at real tensions (the $99/yr funding gap in Open Question 3, explicitly marked phase-blocking) rather than safe checkpoints. §7's framing of the telemetry/measurability trade-off ("a direct, intentional trade-off against the privacy positioning, not an oversight") is exactly the kind of honest trade-off surfacing this dimension rewards.

### Findings
None — no findings needed for a strong dimension.

## Substance over theater — adequate
Both UJs earn their place: UJ-1 drives FR-1, FR-2, FR-9, FR-11–FR-14; UJ-2 drives FR-17–FR-19 directly. No persona theater. Innovation theater is explicitly avoided — Vision disclaims novel-algorithm claims, and §Aesthetic and Tone instructs crediting PhotoRec/TestDisk by name rather than implying invention. NFR theater is mostly absent: the Performance NFR explicitly refuses to promise a throughput number and reframes around responsiveness instead of boilerplate "must be scalable" language.

### Findings
- **low** Accessibility NFR is generic (§Cross-Cutting NFRs) — "Standard Apple HIG compliance, including VoiceOver support" is closer to boilerplate than a product-specific threshold, though it's appropriately flagged as an assumption and low-stakes for this product. *Fix:* leave as-is unless accessibility becomes a differentiator; not worth more rigor at current stakes.

## Strategic coherence — strong
The thesis (a tool worth verifying, not trusting) is stated once in Vision and then actually constrains the rest of the document: §4.6 is a first-class feature section built around it, SM-1/SM-2 validate adoption *of the trust story* rather than generic engagement metrics, and all three counter-metrics (SM-C1–C3) exist specifically to stop the thesis from eroding under its own success (SM-C3 is the standout — "don't add anonymous usage stats under adoption pressure" is a thesis-defending counter-metric, not a filler one). MVP scope reads as a coherent "problem-solving + experience" cut: broad device/filesystem coverage paired with the trust feature set, not a grab-bag.

### Findings
None — no findings needed for a strong dimension.

## Done-ness clarity — thin
This is the dimension downstream story creation leans on hardest, and it's uneven. FR-1, FR-2, FR-3, FR-4, FR-6, FR-7, FR-10, FR-15, and FR-17 all have explicit, testable "Consequences" bullets. FR-5, FR-8, FR-9, FR-11, FR-13, FR-14, FR-16, FR-18, and FR-19 do not — roughly half the FR set breaks the pattern the document itself establishes.

### Findings
- **critical** FR-12 (Recovery confidence indicator, §4.5) has no testable consequence at all — just "must be conservative — never implying more certainty than the recovery method actually supports," with the actual scoring mechanism deferred to Open Question 7. This is the single FR the product's core trust claim and SM-C1 most depend on; shipping it without a testable bound is the done-ness equivalent of the rubric's "system handles X gracefully" red flag. *Fix:* add minimal testable bounds now — e.g. "files recovered via FR-7 carving are never labeled High," "every file recovered via FR-4 with no partial-overwrite evidence is labeled High" — or explicitly mark FR-12 as blocked on Open Question 7 before it's handed to Epics & Stories.
- **high** Nine FRs (FR-5, FR-8, FR-9, FR-11, FR-13, FR-14, FR-16, FR-18, FR-19) lack explicit testable consequences, inconsistent with the other ten. FR-19 is the sharpest instance — "plain-language explanation... exactly what it reads and writes" is adjective-driven ("plain-language," "exactly") without a verifiable bound (shown where, available when, reviewed against what standard). *Fix:* add at least one testable consequence per FR; prioritize FR-19 and FR-9 next after FR-12 above, since both carry real product risk (trust claim, and the lost-partition result's correctness respectively).

## Scope honesty — strong
Non-Goals (§5) does real work — nine specific, reasoned exclusions, not a vague catch-all. The six `[ASSUMPTION]` tags are flagged where inferred rather than silently assumed (barring one roundtrip issue noted below), and the two `[NOTE FOR PM]` callouts sit at genuine unresolved tensions (funding, and the deferred signature-library scope). Nothing here reads as a hidden omission.

### Findings
- **medium** Open-items density is high for a PRD meant to green-light building: 8 Open Questions + 6 Assumptions + 2 `[NOTE FOR PM]` callouts (16 total). Several are legitimate pre-Architecture technical spikes (SIP/FDA mechanics, confidence-scoring methodology) that belong at this stage. But three — product name, license, and notarization funding — are business-level decisions carried forward unresolved for a second time from the brief. Nothing is hidden (that's why this is scope-honesty-strong, not a dishonesty finding), but as a practical matter these three should close in a real conversation before Epics & Stories starts, not keep riding as open questions into implementation. *Fix:* no PRD edit needed; flag to the user as a pre-Epics checklist item.

## Downstream usability — strong
Glossary is present and its 13 terms are used consistently across FRs/UJs (APFS/HFS+/FAT32/exFAT, "recovery confidence," "lost partition," etc.). FR IDs run FR-1 through FR-19 with no gaps or duplicates; UJ-1/UJ-2 and SM-1–4/SM-C1–3 are likewise contiguous. Cross-references resolve (e.g., FR-10's "per FR-4/FR-7," UJ-1's inline FR citations). Both UJs have named protagonists (Sam, Priya) carrying context inline, with no floating/unnamed UJs. As a chain-top PRD feeding UX, Architecture, and Epics & Stories, this dimension matters most here and it holds up.

### Findings
None — no findings needed for a strong dimension.

## Shape fit — strong
This is a consumer product with meaningful UX, so named-protagonist UJs are load-bearing — exactly what's here, at a proportionate count (2, not over-formalized for the stakes). It's also chain-top (feeds UX → Architecture → Epics & Stories), where downstream usability matters more, and the document is built for that extraction. No over- or under-formalization observed.

### Findings
None — no findings needed for a strong dimension.

## Mechanical notes
- **Assumptions Index roundtrip failure (medium):** the MIT-license assumption is indexed ("§Constraints / Monetization: license defaulted to MIT") but does not appear inline anywhere in the PRD body — neither §Monetization nor §Constraints and Guardrails mentions a license at all. Either add an inline `[ASSUMPTION: MIT license, pending confirmation]` tag where the license belongs, or drop the index entry (Open Question 2 already covers the open license decision, but the index entry currently points at nothing).
- **Assumptions Index section labels (low):** two entries cite "§Constraints / Platform" and "§Constraints / Monetization," but Platform and Monetization are both standalone top-level sections, not subsections of "Constraints and Guardrails." Correct the labels to match actual headings.
- **Terminology drift (low):** "Lost Partition" / "lost partition" and "recovery confidence" / "recovery-confidence" capitalization and hyphenation vary across the document — likely intentional (Title Case for the literal UI label/result category vs. lowercase for the general glossary term) but worth confirming and applying uniformly.
- **Inline assumption format inconsistency (low):** the Accessibility NFR's tag (`[ASSUMPTION — see Assumptions Index]`) doesn't restate the assumption inline the way FR-2's and the Platform section's tags do (`[ASSUMPTION: <content>]`). Minor, but worth matching the document's own convention.
- ID continuity: clean — FR-1–19, UJ-1–2, SM-1–4/SM-C1–3 all contiguous with no gaps, duplicates, or unresolved cross-references found.
- Required sections for launch-grade, consumer/chain-top stakes: all present (full Essential Spine plus Cross-Cutting NFRs, Constraints and Guardrails, Monetization, Platform, Aesthetic and Tone, Information Architecture). "Why Now" was reasonably omitted — timing isn't separately load-bearing beyond what Vision already carries.
