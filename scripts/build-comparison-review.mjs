#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const home = process.env.HOME;
const repoRoot = path.resolve(import.meta.dirname, "..");
const defaultOutputDir = path.join(repoRoot, "build.noindex", "comparison-review");
const outputDir = process.argv[2] ? path.resolve(process.argv[2]) : defaultOutputDir;
const logPath = path.join(
  home,
  "Library/Containers/com.teamwong.yaprflow/Data/Library/Application Support/yaprflow/comparison-log.jsonl",
);
const wisprDB = path.join(home, "Library/Application Support/Wispr Flow/flow.sqlite");
const candidatePath = path.join(outputDir, "candidate-results.jsonl");
const selectionPath = path.join(outputDir, "review-selection.json");
const providedReviewsPath = path.join(
  home,
  "Downloads",
  "yaprflow-human-gold-reviews.json",
);

const readJSONL = (file) => fs.readFileSync(file, "utf8")
  .split(/\r?\n/)
  .filter(Boolean)
  .map((line) => JSON.parse(line));

const normalize = (text = "") => text
  .toLowerCase()
  .replace(/[^\p{L}\p{N}']+/gu, " ")
  .trim()
  .replace(/\s+/g, " ");

const tokens = (text) => normalize(text).split(" ").filter(Boolean);

function multisetF1(a, b) {
  const left = tokens(a);
  const right = tokens(b);
  if (!left.length || !right.length) return 0;
  const counts = new Map();
  for (const token of left) counts.set(token, (counts.get(token) ?? 0) + 1);
  let overlap = 0;
  for (const token of right) {
    const count = counts.get(token) ?? 0;
    if (count > 0) {
      overlap += 1;
      counts.set(token, count - 1);
    }
  }
  return (2 * overlap) / (left.length + right.length);
}

function bigramDice(a, b) {
  const left = normalize(a);
  const right = normalize(b);
  if (!left || !right) return 0;
  if (left === right) return 1;
  const grams = new Map();
  for (let i = 0; i < left.length - 1; i += 1) {
    const gram = left.slice(i, i + 2);
    grams.set(gram, (grams.get(gram) ?? 0) + 1);
  }
  let overlap = 0;
  for (let i = 0; i < right.length - 1; i += 1) {
    const gram = right.slice(i, i + 2);
    const count = grams.get(gram) ?? 0;
    if (count > 0) {
      overlap += 1;
      grams.set(gram, count - 1);
    }
  }
  return (2 * overlap) / Math.max(1, left.length + right.length - 2);
}

const similarity = (a, b) => 0.72 * multisetF1(a, b) + 0.28 * bigramDice(a, b);

function tokenEditSimilarity(a, b) {
  const left = tokens(a);
  const right = tokens(b);
  if (!left.length && !right.length) return 1;
  if (!left.length || !right.length) return 0;
  let previous = Array.from({ length: right.length + 1 }, (_, index) => index);
  let current = new Array(right.length + 1).fill(0);
  for (let i = 1; i <= left.length; i += 1) {
    current[0] = i;
    for (let j = 1; j <= right.length; j += 1) {
      const cost = left[i - 1] === right[j - 1] ? 0 : 1;
      current[j] = Math.min(
        previous[j] + 1,
        current[j - 1] + 1,
        previous[j - 1] + cost,
      );
    }
    [previous, current] = [current, previous];
  }
  return 1 - previous[right.length] / Math.max(left.length, right.length);
}

function validatorDecision(candidate, original) {
  if (!candidate?.trim()) return { accepted: false, reason: "empty" };
  if (tokens(original).length < 4) return { accepted: false, reason: "short-input skip" };
  const expansionLimit = Math.max(original.length * 2, original.length + 80);
  if (candidate.length > expansionLimit) {
    return { accepted: false, reason: "over-expanded" };
  }
  const editSimilarity = tokenEditSimilarity(candidate, original);
  if (editSimilarity < 0.55) {
    return { accepted: false, reason: "rewrite similarity" };
  }
  const lower = candidate.toLowerCase();
  const lowerOriginal = original.toLowerCase();
  const assistantMarkers = [
    "sure,",
    "here's",
    "here is",
    "actionable step",
    "step plan",
    "how do you want",
    "i can help",
    "as an ai",
    "let me know",
  ];
  const introducedMarker = assistantMarkers.find(
    (marker) => lower.includes(marker) && !lowerOriginal.includes(marker),
  );
  if (introducedMarker) {
    return { accepted: false, reason: `assistant marker: ${introducedMarker}` };
  }
  return { accepted: true, reason: null };
}

function normalizeModelOutput(value) {
  let text = (value ?? "").trim();
  if (!text) return text;
  try {
    const decoded = JSON.parse(text);
    if (typeof decoded === "string") return decoded.trim();
    if (decoded && typeof decoded.transcript === "string") {
      return decoded.transcript.trim();
    }
    if (Array.isArray(decoded) && decoded.length === 1) {
      if (typeof decoded[0] === "string") return decoded[0].trim();
      if (decoded[0] && typeof decoded[0].transcript === "string") {
        return decoded[0].transcript.trim();
      }
    }
  } catch {
    // Plain text is the expected path.
  }
  return text
    .replace(/^transcript["']?\s*[:=]?\s*/i, "")
    .replace(/^["']|["']$/g, "")
    .trim();
}

function parseWisprTimestamp(value) {
  return Date.parse(value.replace(" ", "T").replace(" +00:00", "Z"));
}

function lowerBound(rows, target) {
  let low = 0;
  let high = rows.length;
  while (low < high) {
    const mid = (low + high) >>> 1;
    if (rows[mid].endMs < target) low = mid + 1;
    else high = mid;
  }
  return low;
}

const logRows = readJSONL(logPath);
const polishBySession = new Map(
  logRows
    .filter((row) => row.recordType === "polishResult" && row.sessionID)
    .map((row) => [row.sessionID, row]),
);
const yaprRows = logRows.filter((row) => row.raw && row.recordType !== "polishResult");

const wisprSQL = `
  SELECT
    rowid AS wisprRowID,
    timestamp,
    duration,
    app,
    asrText,
    formattedText,
    e2eLatency
  FROM History
  WHERE asrText IS NOT NULL AND asrText != ''
  ORDER BY timestamp
`;
const wisprRows = JSON.parse(execFileSync(
  "sqlite3",
  ["-readonly", "-json", wisprDB, wisprSQL],
  { encoding: "utf8", maxBuffer: 256 * 1024 * 1024 },
)).map((row) => {
  const startMs = parseWisprTimestamp(row.timestamp);
  return {
    ...row,
    startMs,
    endMs: startMs + Number(row.duration ?? 0) * 1_000,
  };
}).sort((a, b) => a.endMs - b.endMs);

const usedWisprRows = new Set();
const pairs = [];

for (const yapr of yaprRows.sort((a, b) => Date.parse(a.ts) - Date.parse(b.ts))) {
  const anchorMs = Date.parse(yapr.recordingStoppedAt ?? yapr.ts);
  const windowMs = 4_500;
  let cursor = lowerBound(wisprRows, anchorMs - windowMs);
  let best = null;

  while (cursor < wisprRows.length && wisprRows[cursor].endMs <= anchorMs + windowMs) {
    const wispr = wisprRows[cursor];
    cursor += 1;
    if (usedWisprRows.has(wispr.wisprRowID)) continue;
    const endDiffMs = Math.abs(wispr.endMs - anchorMs);
    const rawSimilarity = Math.max(
      similarity(yapr.raw, wispr.asrText),
      similarity(yapr.raw, wispr.formattedText),
    );
    const rank = rawSimilarity - (endDiffMs / 1_000) * 0.018;
    if (!best || rank > best.rank) {
      best = { wispr, endDiffMs, rawSimilarity, rank };
    }
  }

  if (!best || best.rawSimilarity < 0.62) continue;
  usedWisprRows.add(best.wispr.wisprRowID);

  const sessionID = yapr.sessionID ?? `legacy-${yapr.ts}`;
  const polishEvent = polishBySession.get(yapr.sessionID);
  const rawWords = tokens(yapr.raw).length;
  const wisprRawSimilarity = similarity(yapr.raw, best.wispr.asrText);
  const wisprFormattedSimilarity = similarity(yapr.raw, best.wispr.formattedText);
  const normalizedSame = normalize(best.wispr.asrText) === normalize(best.wispr.formattedText);
  const fillerMatches = yapr.raw.match(/\b(?:um+|uh+|like|you know|i guess|kind of|sort of)\b/gi) ?? [];
  const endingWindow = tokens(yapr.raw).slice(-18).join(" ");
  const trailing = /\b(?:and|but|or|so|because|like|though|anyway)[,.…]?\s*$/i.test(yapr.raw)
    || /\b(?:i don't know|something like that|at the same time|so yeah|but yeah|or something|and stuff|and all that|throwing that out there|you know whatever)\b/i.test(endingWindow);

  const tags = [];
  const lengthBand = rawWords <= 15 ? "short" : rawWords <= 65 ? "medium" : "long";
  tags.push(lengthBand);
  if (trailing) tags.push("trailing-thought");
  if (fillerMatches.length >= 2) tags.push("filler-heavy");
  if (wisprRawSimilarity < 0.9) tags.push("asr-disagreement");
  if (normalizedSame && best.wispr.asrText !== best.wispr.formattedText) {
    tags.push("punctuation-only");
  }
  if (yapr.schemaVersion === 2) tags.push("new-shadow");

  const legacyOther = yapr.other?.trim() || null;
  const legacyOtherReliable = legacyOther
    ? similarity(legacyOther, best.wispr.formattedText) >= 0.78
    : null;
  if (legacyOther && !legacyOtherReliable) tags.push("legacy-clipboard-mismatch");

  pairs.push({
    id: sessionID,
    ts: yapr.ts,
    app: best.wispr.app,
    durationSeconds: best.wispr.duration,
    wordCount: rawWords,
    lengthBand,
    tags,
    yapr: {
      raw: yapr.raw,
      light: yapr.light ?? yapr.raw,
      historicalSelected: yapr.polished ?? null,
      currentPolish: polishEvent?.polish ?? null,
      currentPolishStatus: polishEvent?.polishStatus ?? null,
      cleanupMode: yapr.cleanupMode ?? null,
      asrReadyMs: yapr.yaprASRReadyMs ?? null,
      readyMs: yapr.yaprReadyMs ?? null,
    },
    wispr: {
      raw: best.wispr.asrText,
      formatted: best.wispr.formattedText,
      latencyMs: best.wispr.e2eLatency,
      rowID: best.wispr.wisprRowID,
    },
    legacyOther: legacyOtherReliable ? legacyOther : null,
    metrics: {
      recordingEndDifferenceMs: Math.round(best.endDiffMs),
      rawSimilarity: Number(best.rawSimilarity.toFixed(4)),
      wisprRawSimilarity: Number(wisprRawSimilarity.toFixed(4)),
      wisprFormattedSimilarity: Number(wisprFormattedSimilarity.toFixed(4)),
      legacyOtherReliable,
    },
  });
}

const candidates = fs.existsSync(candidatePath) ? readJSONL(candidatePath) : [];
const candidateByPair = new Map();
for (const result of candidates) {
  if (!candidateByPair.has(result.id)) candidateByPair.set(result.id, {});
  candidateByPair.get(result.id)[result.modelKey] = result;
}
for (const pair of pairs) {
  pair.candidates = candidateByPair.get(pair.id) ?? {};
  for (const result of Object.values(pair.candidates)) {
    if (result.output) {
      result.rawModelOutput = result.output;
      result.output = normalizeModelOutput(result.output);
    }
    const candidate = result.output ?? "";
    const decision = validatorDecision(candidate, pair.yapr.raw);
    result.tokenSimilarity = Number(
      tokenEditSimilarity(candidate, pair.yapr.raw).toFixed(4),
    );
    result.charDelta = candidate.length - pair.yapr.raw.length;
    result.validatorAccepted = decision.accepted;
    result.validatorFallbackReason = decision.reason;
  }
}

function interestScore(pair) {
  let score = (1 - pair.metrics.wisprRawSimilarity) * 4;
  if (pair.tags.includes("trailing-thought")) score += 1.4;
  if (pair.tags.includes("filler-heavy")) score += 1.1;
  if (pair.tags.includes("punctuation-only")) score += 0.8;
  if (pair.tags.includes("new-shadow")) score += 1.2;
  if (pair.tags.includes("legacy-clipboard-mismatch")) score += 0.3;
  score += Math.min(pair.wordCount, 180) / 300;
  return score;
}

function chooseBucket(bucket, quota) {
  const ranked = [...bucket].sort((a, b) => interestScore(b) - interestScore(a));
  const chosen = ranked.slice(0, Math.ceil(quota * 0.65));
  const remaining = ranked.filter((item) => !chosen.includes(item))
    .sort((a, b) => Date.parse(a.ts) - Date.parse(b.ts));
  const needed = Math.max(0, quota - chosen.length);
  for (let i = 0; i < needed && remaining.length; i += 1) {
    const index = Math.min(
      remaining.length - 1,
      Math.floor(((i + 0.5) / needed) * remaining.length),
    );
    const item = remaining[index];
    if (!chosen.includes(item)) chosen.push(item);
  }
  return chosen.slice(0, quota);
}

let selectedIDs;
if (fs.existsSync(selectionPath)) {
  const manifest = JSON.parse(fs.readFileSync(selectionPath, "utf8"));
  selectedIDs = new Set(manifest.selectedIDs);
} else {
  selectedIDs = new Set([
    ...chooseBucket(pairs.filter((pair) => pair.lengthBand === "short"), 12),
    ...chooseBucket(pairs.filter((pair) => pair.lengthBand === "medium"), 22),
    ...chooseBucket(pairs.filter((pair) => pair.lengthBand === "long"), 16),
  ].map((pair) => pair.id));
  fs.mkdirSync(outputDir, { recursive: true });
  fs.writeFileSync(selectionPath, `${JSON.stringify({
    schemaVersion: 1,
    createdAt: new Date().toISOString(),
    selectedIDs: [...selectedIDs],
  }, null, 2)}\n`);
}

for (const pair of pairs) {
  pair.selectedForReview = selectedIDs.has(pair.id);
}

pairs.sort((a, b) => Date.parse(a.ts) - Date.parse(b.ts));
const reviewSeed = {
  schemaVersion: 2,
  generatedAt: new Date().toISOString(),
  sources: {
    yaprflowLog: logPath,
    wisprDatabase: wisprDB,
    candidateResults: fs.existsSync(candidatePath) ? candidatePath : null,
  },
  summary: {
    matchedPairs: pairs.length,
    selectedPairs: pairs.filter((pair) => pair.selectedForReview).length,
    shadowPairs: pairs.filter((pair) => pair.tags.includes("new-shadow")).length,
  },
  importedReviews: fs.existsSync(providedReviewsPath)
    ? (JSON.parse(fs.readFileSync(providedReviewsPath, "utf8")).reviews ?? {})
    : {},
  pairs,
};

fs.mkdirSync(outputDir, { recursive: true });
fs.writeFileSync(
  path.join(outputDir, "review-seed.json"),
  `${JSON.stringify(reviewSeed, null, 2)}\n`,
);

const dataBase64 = Buffer.from(JSON.stringify(reviewSeed), "utf8").toString("base64");
const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Yaprflow Dictation Review</title>
<style>
:root{color-scheme:dark;--bg:#090b10;--panel:#11151d;--panel2:#171c26;--line:#293140;--text:#f2f5f8;--muted:#99a4b3;--blue:#78a9ff;--green:#52d6a1;--amber:#ffc66d;--red:#ff7f87;--violet:#b69cff}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 80% -10%,#1c2440 0,transparent 38%),var(--bg);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
button,input,textarea,select{font:inherit;color:inherit}button{border:1px solid var(--line);background:#171d28;border-radius:9px;padding:7px 10px;cursor:pointer}button:hover{border-color:#4e607a}.active,.primary{background:#264f87;border-color:#578ed5}.shell{display:grid;grid-template-columns:270px minmax(0,1fr);min-height:100vh}
aside{position:sticky;top:0;height:100vh;border-right:1px solid var(--line);padding:18px;background:#0c0f15e8;overflow:auto}.brand{font-size:18px;font-weight:720}.sub{color:var(--muted);font-size:12px;margin:4px 0 18px}.label{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.08em;margin:17px 0 7px}.presets{display:grid;gap:6px}.presets button{text-align:left}.stats{display:grid;grid-template-columns:1fr 1fr;gap:7px}.stat{padding:10px;background:var(--panel);border:1px solid var(--line);border-radius:10px}.stat b{display:block;font-size:18px}.stat span{color:var(--muted);font-size:11px}
main{padding:22px;min-width:0}.toolbar{display:flex;gap:8px;align-items:center;position:sticky;top:0;z-index:3;padding:10px;background:#090b10e8;backdrop-filter:blur(14px);border:1px solid var(--line);border-radius:13px}.toolbar input{flex:1;background:#111722;border:1px solid var(--line);border-radius:9px;padding:8px 10px}.counter{color:var(--muted);white-space:nowrap}
.header{display:flex;justify-content:space-between;gap:20px;margin:22px 2px 12px}.header h1{font-size:20px;margin:0 0 4px}.meta,.tags{display:flex;gap:6px;flex-wrap:wrap;color:var(--muted);font-size:12px}.tag{border:1px solid var(--line);border-radius:999px;padding:2px 7px}.tag.warn{border-color:#714f2c;color:var(--amber)}
.guide{margin-top:12px;background:#101620;border:1px solid var(--line);border-radius:12px;padding:10px 13px;color:#cbd4df}.guide summary{cursor:pointer;font-weight:700;color:var(--text)}.guide ol{margin:9px 0 2px;padding-left:20px}.guide b{color:var(--blue)}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.card{position:relative;background:linear-gradient(145deg,#141924,#10141c);border:1px solid var(--line);border-radius:13px;padding:14px;min-height:170px}.card.rejected{border-color:#6b3c43}.card.chosen,.card.judged-acceptable{border-color:var(--green);box-shadow:0 0 0 1px #52d6a122}.card.judged-context_loss{border-color:var(--red);box-shadow:0 0 0 1px #ff7f8722}.card h2{font-size:12px;margin:0 0 6px;color:var(--blue);display:flex;justify-content:space-between;gap:10px}.change-summary{font:11px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--muted);margin-bottom:9px}.context-risk{font:11px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--amber);padding:6px 8px;background:#2a2114;border-radius:6px;margin:0 0 9px}.card p{white-space:pre-wrap;margin:0 0 42px;font-size:14px}.card .empty{color:#667181;font-style:italic}.card-actions{display:flex;gap:5px;position:absolute;left:10px;right:10px;bottom:10px}.card-actions button{padding:4px 7px;font-size:11px;opacity:.72}.card:hover .card-actions button,.card-actions button.active{opacity:1}.card-actions .accept.active{background:#184b39;border-color:var(--green)}.card-actions .loss.active{background:#51252b;border-color:var(--red)}.card-actions .prefer{margin-left:auto}.metric{font:11px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--muted)}.metric.reject{color:var(--red)}ins{color:#9af0c8;background:#163c2e;text-decoration:underline 2px var(--green);text-underline-offset:3px;border-radius:3px;padding:0 2px}del{color:#ffabb0;background:#422027;text-decoration:line-through 2px var(--red);border-radius:3px;padding:0 2px}
.review{margin-top:12px;background:var(--panel);border:1px solid var(--line);border-radius:13px;padding:14px}.review textarea,.review input[type="text"]{width:100%;resize:vertical;background:#0d1118;border:1px solid var(--line);border-radius:10px;padding:11px;line-height:1.5}.review textarea{min-height:130px}.review textarea.notes{min-height:72px;margin-top:10px}.review input[type="text"]{margin:10px 0}.decision{display:flex;gap:7px;flex-wrap:wrap;margin:0 0 12px}.decision button.active{background:#264f87;border-color:var(--blue)}.reviewbar{display:flex;justify-content:space-between;gap:10px;align-items:center;margin-bottom:9px}.flags{display:flex;gap:12px;flex-wrap:wrap;color:var(--muted);font-size:12px}.flags label{display:flex;gap:5px;align-items:center}.prompt{margin-top:12px;background:#0e1219;border:1px solid var(--line);border-radius:13px;padding:13px}.prompt pre{white-space:pre-wrap;color:#cbd4df;font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}.footer-actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}.notice{padding:10px;border-left:3px solid var(--amber);background:#2a2114;color:#ecd3a8;border-radius:6px;font-size:12px}.kbd{font:11px ui-monospace,SFMono-Regular,Menlo,monospace;border:1px solid var(--line);border-bottom-width:2px;border-radius:5px;padding:1px 5px;color:var(--muted)}
@media(max-width:900px){.shell{display:block}aside{position:relative;height:auto;border-right:0;border-bottom:1px solid var(--line)}.grid{grid-template-columns:1fr}main{padding:12px}}
</style>
</head>
<body>
<div class="shell">
<aside>
  <div class="brand">Dictation Review</div>
  <div class="sub">Local-only human gold-target builder</div>
  <div class="stats">
    <div class="stat"><b id="matchedStat">0</b><span>matched</span></div>
    <div class="stat"><b id="reviewedStat">0</b><span>reviewed</span></div>
    <div class="stat"><b id="selectedStat">0</b><span>review set</span></div>
    <div class="stat"><b id="remainingStat">0</b><span>remaining</span></div>
  </div>
  <div class="label">Presets</div>
  <div class="presets" id="presets">
    <button data-preset="selected">Representative 50</button>
    <button data-preset="context">Possible context loss</button>
    <button data-preset="problems">ASR disagreements</button>
    <button data-preset="needsDecision">Prior choices to classify</button>
    <button data-preset="unreviewed">Unreviewed only</button>
  </div>
  <div class="label">Review status</div>
  <div class="notice">You do not need to pick a stylistic winner. Mark several outputs acceptable when they preserve the same meaning. Context loss is the critical failure.</div>
  <div class="label">Shortcuts</div>
  <div class="sub"><span class="kbd">←</span>/<span class="kbd">→</span> navigate<br><span class="kbd">1–8</span> choose candidate<br><span class="kbd">E</span> edit ideal</div>
</aside>
<main>
  <div class="toolbar">
    <button id="prev">← Previous</button>
    <button id="next">Next →</button>
    <button id="toggleDiff" class="active">Changes highlighted</button>
    <input id="search" placeholder="Search transcript, app, or tag">
    <span class="counter" id="counter"></span>
  </div>
  <details class="guide" open>
    <summary>How to use this review</summary>
    <ol>
      <li><b>Yaprflow Raw</b> is what local speech recognition heard. It is the comparison baseline.</li>
      <li><b>Yaprflow Light</b> only applies safe mechanical cleanup. Green underlines are additions; red strikeouts are removals compared with Raw.</li>
      <li>Compare Wispr and each local grammar model. A red-bordered model would be rejected by Yaprflow’s safety validator and fall back to Raw.</li>
      <li>If several versions sound equally good, mark all of them <b>Acceptable</b> and choose <b>Several are fine</b>. No stylistic winner is required.</li>
      <li>Use <b>Context missing</b> when an important word, qualifier, relationship, or intent disappeared. Record the critical word or meaning below.</li>
      <li>Only use <b>Prefer this</b> or edit an ideal when one version is clearly better or none are acceptable.</li>
      <li>Use <b>Save & next</b>, then export the reviewed JSON when finished.</li>
    </ol>
  </details>
  <section id="item"></section>
  <section class="prompt">
    <div class="reviewbar"><strong>Review brief</strong><button id="copyPrompt">Copy brief</button></div>
    <pre id="promptText"></pre>
    <div class="footer-actions">
      <button class="primary" id="saveReview">Save review</button>
      <button id="exportReviews">Export reviewed JSON</button>
      <button id="importReviews">Import review JSON</button>
      <input type="file" id="importFile" accept=".json" hidden>
    </div>
  </section>
</main>
</div>
<script>
const DATA=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob("${dataBase64}"),c=>c.charCodeAt(0))));
const STORAGE_KEY="yaprflow-dictation-review-v1";
const candidateDefs=[
  ["raw","Yaprflow Raw",p=>p.yapr.raw],
  ["light","Yaprflow Light",p=>p.yapr.light],
  ["wisprRaw","Wispr Raw",p=>p.wispr.raw],
  ["wisprFormatted","Wispr Formatted",p=>p.wispr.formatted],
  ["currentPolish","Current Qwen2.5 Polish",p=>p.candidates.qwen25?.output||p.yapr.currentPolish],
  ["qwen3","Qwen3 1.7B",p=>p.candidates.qwen3?.output],
  ["qwen35","Qwen3.5 2B",p=>p.candidates.qwen35?.output],
  ["lfm25","LFM2.5 1.2B",p=>p.candidates.lfm25?.output],
];
const state={preset:Object.keys(DATA.importedReviews||{}).length?"needsDecision":"selected",query:"",index:0,showDiff:true,reviews:loadReviews()};
function loadReviews(){try{return {...(DATA.importedReviews||{}),...JSON.parse(localStorage.getItem(STORAGE_KEY)||"{}")}}catch{return {...(DATA.importedReviews||{})}}}
function persist(){localStorage.setItem(STORAGE_KEY,JSON.stringify(state.reviews));updateStats()}
function isReviewed(review){return Boolean(review&&(review.decision||review.ideal?.trim()||Object.keys(review.candidateJudgments||{}).length))}
function filtered(){
  const q=state.query.toLowerCase().trim();
  return DATA.pairs.filter(p=>{
    const r=state.reviews[p.id];
    let ok=true;
    if(state.preset==="selected")ok=p.selectedForReview;
    if(state.preset==="problems")ok=p.tags.includes("asr-disagreement");
    if(state.preset==="context")ok=candidateDefs.some(([, ,get])=>meaningfulRemoved(p.yapr.raw,get(p)).length);
    if(state.preset==="needsDecision")ok=Boolean(r?.chosen&&!r?.decision);
    if(state.preset==="unreviewed")ok=!isReviewed(r);
    if(q)ok=ok&&[p.yapr.raw,p.wispr.raw,p.wispr.formatted,p.app,...p.tags].join(" ").toLowerCase().includes(q);
    return ok;
  });
}
const esc=s=>(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","\\"":"&quot;","'":"&#39;"}[c]));
function diffTokens(text){
  return [...(text||"").matchAll(/(\\s*)([\\p{L}\\p{N}']+|[^\\s\\p{L}\\p{N}])/gu)].map(m=>({prefix:m[1],text:m[2],key:m[2].toLowerCase()}));
}
function diffMarkup(base,candidate){
  if(base===candidate)return {html:esc(candidate),added:0,removed:0};
  const a=diffTokens(base),b=diffTokens(candidate),rows=a.length+1,cols=b.length+1;
  const dp=Array.from({length:rows},()=>new Uint16Array(cols));
  for(let i=1;i<rows;i++)for(let j=1;j<cols;j++)dp[i][j]=a[i-1].key===b[j-1].key?dp[i-1][j-1]+1:Math.max(dp[i-1][j],dp[i][j-1]);
  const ops=[];let i=a.length,j=b.length,added=0,removed=0;
  while(i||j){
    if(i&&j&&a[i-1].key===b[j-1].key){ops.push({type:"same",token:b[j-1]});i--;j--}
    else if(j&&(!i||dp[i][j-1]>=dp[i-1][j])){ops.push({type:"add",token:b[j-1]});added++;j--}
    else{ops.push({type:"remove",token:a[i-1]});removed++;i--}
  }
  ops.reverse();
  const html=ops.map(op=>{const value=esc(op.token.prefix+op.token.text);return op.type==="add"?"<ins>"+value+"</ins>":op.type==="remove"?"<del>"+value+"</del>":value}).join("");
  return {html,added,removed};
}
const contextStopWords=new Set("a an and are as at be been but by do does for from had has have he her him his i if in is it its me my of on or our she so that the their them then there they this to was we were what when where which who will with would you your okay yeah just like guess think know kind sort gonna want wants wanted maybe really something stuff thing things um uh".split(" "));
function meaningfulRemoved(base,candidate){
  if(!candidate)return [];
  const keep=token=>token.length>=3&&!contextStopWords.has(token);
  const before=diffTokens(base).map(t=>t.key).filter(keep),after=diffTokens(candidate).map(t=>t.key).filter(keep);
  const counts=new Map();after.forEach(t=>counts.set(t,(counts.get(t)||0)+1));
  const removed=new Map();
  before.forEach(t=>{const n=counts.get(t)||0;if(n)counts.set(t,n-1);else removed.set(t,(removed.get(t)||0)+1)});
  return [...removed].map(([word,count])=>count>1?word+" ×"+count:word);
}
function current(){const items=filtered();if(!items.length)return null;state.index=Math.max(0,Math.min(state.index,items.length-1));return items[state.index]}
function choose(key,text){const p=current();if(!p||!text)return;state.reviews[p.id]={...(state.reviews[p.id]||{}),decision:"strong_preference",chosen:key,ideal:text,updatedAt:new Date().toISOString()};persist();render()}
function judge(key,value){
  const p=current();if(!p)return;const review=state.reviews[p.id]||{},judgments={...(review.candidateJudgments||{})};
  if(judgments[key]===value)delete judgments[key];else judgments[key]=value;
  state.reviews[p.id]={...review,candidateJudgments:judgments,updatedAt:new Date().toISOString()};persist();render();
}
function setDecision(value){
  const p=current();if(!p)return;const review=state.reviews[p.id]||{};
  state.reviews[p.id]={...review,decision:review.decision===value?null:value,updatedAt:new Date().toISOString()};persist();render();
  if(value==="none_acceptable")document.getElementById("ideal")?.focus();
}
function render(){
  const items=filtered(),p=current(),root=document.getElementById("item");
  document.querySelectorAll("[data-preset]").forEach(b=>b.classList.toggle("active",b.dataset.preset===state.preset));
  document.getElementById("counter").textContent=p?((state.index+1)+" of "+items.length):"0 results";
  if(!p){root.innerHTML='<div class="header"><h1>No matching examples</h1></div>';updateStats();return}
  const review=state.reviews[p.id]||{};
  const cards=candidateDefs.map(([key,label,get],i)=>{
    const text=get(p),result=p.candidates[key],chosen=review.chosen===key,rejected=result&&result.validatorAccepted===false,judgment=review.candidateJudgments?.[key];
    const metric=result?.latencyMs?('<span class="metric '+(rejected?"reject":"")+'">'+Math.round((result.tokenSimilarity||0)*100)+'% · '+(rejected?('fallback: '+result.validatorFallbackReason):'accepted')+' · '+Math.round(result.latencyMs)+' ms</span>'):"";
    const diff=text&&state.showDiff&&key!=="raw"?diffMarkup(p.yapr.raw,text):{html:esc(text||"Pending candidate generation"),added:0,removed:0};
    const changeSummary=!text?"not generated":key==="raw"?"comparison baseline":diff.added||diff.removed?("+"+diff.added+" added · −"+diff.removed+" removed"):"no changes from Raw";
    const contextTerms=key==="raw"?[]:meaningfulRemoved(p.yapr.raw,text);
    const contextRisk=contextTerms.length?'<div class="context-risk">Possible context loss: '+esc(contextTerms.slice(0,8).join(", "))+(contextTerms.length>8?"…":"")+'</div>':"";
    const actions=text?'<div class="card-actions"><button class="accept '+(judgment==="acceptable"?"active":"")+'" data-judge="'+key+'" data-value="acceptable">Acceptable</button><button class="loss '+(judgment==="context_loss"?"active":"")+'" data-judge="'+key+'" data-value="context_loss">Context missing</button><button class="prefer" data-choose="'+key+'">Prefer this</button></div>':"";
    return '<article class="card '+(chosen?"chosen ":"")+(rejected?"rejected ":"")+(judgment?("judged-"+judgment):"")+'"><h2><span>'+(i+1)+'. '+label+'</span>'+metric+'</h2><div class="change-summary">'+changeSummary+'</div>'+contextRisk+'<p class="'+(!text?"empty":"")+'">'+diff.html+'</p>'+actions+'</article>';
  }).join("");
  const legacyChoice=review.chosen&&!review.decision?'<span class="metric">Previous choice preserved; preference strength not set</span>':"";
  root.innerHTML='<div class="header"><div><h1>'+esc(p.yapr.raw.slice(0,72))+(p.yapr.raw.length>72?"…":"")+'</h1><div class="meta"><span>'+new Date(p.ts).toLocaleString()+'</span><span>'+esc(p.app||"unknown app")+'</span><span>'+p.wordCount+' words</span><span>pair Δ '+p.metrics.recordingEndDifferenceMs+' ms</span></div></div><div class="tags">'+p.tags.map(t=>'<span class="tag '+(t.includes("mismatch")||t.includes("disagreement")?"warn":"")+'">'+esc(t)+'</span>').join("")+'</div></div><div class="grid">'+cards+'</div><div class="review"><div class="reviewbar"><strong>Overall judgment</strong>'+legacyChoice+'</div><div class="decision"><button data-decision="multiple_acceptable" class="'+(review.decision==="multiple_acceptable"?"active":"")+'">Several are fine — no preference</button><button data-decision="strong_preference" class="'+(review.decision==="strong_preference"?"active":"")+'">One is clearly best</button><button data-decision="none_acceptable" class="'+(review.decision==="none_acceptable"?"active":"")+'">None preserve it correctly</button></div><input type="text" id="criticalContext" value="'+esc(review.criticalContext||"")+'" placeholder="Critical word or meaning that must survive, e.g. ‘assets’"><div class="reviewbar"><strong>Ideal output <span class="metric">(optional unless none are acceptable)</span></strong><span class="metric">'+(review.chosen?("based on "+review.chosen):"")+'</span></div><textarea id="ideal" placeholder="Only edit this when you have a clear preference or need to repair a failure…">'+esc(review.ideal||"")+'</textarea><textarea id="reviewNotes" class="notes" placeholder="Comparison notes: what context disappeared, what remained acceptable, or why you edited it…">'+esc(review.notes||"")+'</textarea><div class="reviewbar" style="margin-top:9px"><div class="flags">'+["context_loss","meaning_changed","invented_detail","ending_loss","unwanted_rewrite","asr_error","punctuation","good_as_is"].map(f=>'<label><input type="checkbox" data-flag="'+f+'" '+(review.flags?.includes(f)?"checked":"")+'>'+f.replaceAll("_"," ")+'</label>').join("")+'</div><button id="markReviewed">Save & next</button></div></div>';
  root.querySelectorAll("[data-choose]").forEach(btn=>btn.onclick=()=>{const def=candidateDefs.find(d=>d[0]===btn.dataset.choose);choose(def[0],def[2](p))});
  root.querySelectorAll("[data-judge]").forEach(btn=>btn.onclick=()=>judge(btn.dataset.judge,btn.dataset.value));
  root.querySelectorAll("[data-decision]").forEach(btn=>btn.onclick=()=>setDecision(btn.dataset.decision));
  document.getElementById("ideal").oninput=e=>{state.reviews[p.id]={...(state.reviews[p.id]||{}),chosen:"edited",ideal:e.target.value,updatedAt:new Date().toISOString()};persist();updatePrompt()};
  document.getElementById("criticalContext").oninput=e=>{state.reviews[p.id]={...(state.reviews[p.id]||{}),criticalContext:e.target.value,updatedAt:new Date().toISOString()};persist();updatePrompt()};
  document.getElementById("reviewNotes").oninput=e=>{state.reviews[p.id]={...(state.reviews[p.id]||{}),notes:e.target.value,updatedAt:new Date().toISOString()};persist()};
  root.querySelectorAll("[data-flag]").forEach(box=>box.onchange=()=>{const flags=[...root.querySelectorAll("[data-flag]:checked")].map(x=>x.dataset.flag);state.reviews[p.id]={...(state.reviews[p.id]||{}),flags,updatedAt:new Date().toISOString()};persist()});
  document.getElementById("markReviewed").onclick=()=>{persist();navigate(1)};
  updatePrompt();updateStats();
}
function navigate(delta){const n=filtered().length;if(!n)return;state.index=Math.max(0,Math.min(n-1,state.index+delta));render();scrollTo({top:0,behavior:"smooth"})}
function updateStats(){const reviewed=Object.values(state.reviews).filter(isReviewed).length;const selected=DATA.pairs.filter(p=>p.selectedForReview).length;document.getElementById("matchedStat").textContent=DATA.pairs.length;document.getElementById("reviewedStat").textContent=reviewed;document.getElementById("selectedStat").textContent=selected;document.getElementById("remainingStat").textContent=Math.max(0,selected-DATA.pairs.filter(p=>p.selectedForReview&&isReviewed(state.reviews[p.id])).length)}
function updatePrompt(){
  const p=current(),r=p&&state.reviews[p.id];if(!p){document.getElementById("promptText").textContent="No example selected.";return}
  const judgments=r?.candidateJudgments||{},acceptable=Object.keys(judgments).filter(k=>judgments[k]==="acceptable"),losses=Object.keys(judgments).filter(k=>judgments[k]==="context_loss");
  const decision={multiple_acceptable:"Several outputs are acceptable with no strong stylistic preference.",strong_preference:"One output is clearly preferred.",none_acceptable:"No candidate preserves the intended meaning correctly."}[r?.decision]||"Preference strength has not been set.";
  document.getElementById("promptText").textContent='Review this '+p.wordCount+'-word dictation for faithful cleanup. '+decision+(acceptable.length?' Acceptable candidates: '+acceptable.join(", ")+".":"")+(losses.length?' Context-loss failures: '+losses.join(", ")+".":"")+(r?.criticalContext?.trim()?' Critical context that must survive: '+r.criticalContext.trim()+".":"")+(r?.ideal?.trim()?' Human-edited ideal: '+r.ideal.trim():"");
}
document.getElementById("prev").onclick=()=>navigate(-1);document.getElementById("next").onclick=()=>navigate(1);
document.getElementById("toggleDiff").onclick=e=>{state.showDiff=!state.showDiff;e.currentTarget.classList.toggle("active",state.showDiff);e.currentTarget.textContent=state.showDiff?"Changes highlighted":"Plain text";render()};
document.getElementById("search").oninput=e=>{state.query=e.target.value;state.index=0;render()};
document.querySelectorAll("[data-preset]").forEach(b=>b.onclick=()=>{state.preset=b.dataset.preset;state.index=0;render()});
document.getElementById("copyPrompt").onclick=async e=>{await navigator.clipboard.writeText(document.getElementById("promptText").textContent);const old=e.target.textContent;e.target.textContent="Copied!";setTimeout(()=>e.target.textContent=old,900)};
document.getElementById("saveReview").onclick=()=>persist();
document.getElementById("exportReviews").onclick=()=>{const payload={schemaVersion:2,reviewModel:"acceptability-context-preservation",exportedAt:new Date().toISOString(),sourceGeneratedAt:DATA.generatedAt,reviews:state.reviews};const a=document.createElement("a");a.href=URL.createObjectURL(new Blob([JSON.stringify(payload,null,2)],{type:"application/json"}));a.download="yaprflow-human-gold-reviews.json";a.click();URL.revokeObjectURL(a.href)};
document.getElementById("importReviews").onclick=()=>document.getElementById("importFile").click();
document.getElementById("importFile").onchange=async e=>{const payload=JSON.parse(await e.target.files[0].text()),incoming=payload.reviews||payload;state.reviews={...state.reviews,...incoming};persist();render()};
document.addEventListener("keydown",e=>{if(e.target.matches("textarea,input"))return;if(e.key==="ArrowLeft")navigate(-1);if(e.key==="ArrowRight")navigate(1);if(e.key.toLowerCase()==="e")document.getElementById("ideal")?.focus();const i=Number(e.key)-1;if(i>=0&&i<candidateDefs.length){const p=current(),d=candidateDefs[i],text=d[2](p);if(text)choose(d[0],text)}});
render();
</script>
</body>
</html>`;

const htmlPath = path.join(outputDir, "dictation-review.html");
fs.writeFileSync(htmlPath, html);
console.log(JSON.stringify({
  output: htmlPath,
  seed: path.join(outputDir, "review-seed.json"),
  matchedPairs: reviewSeed.summary.matchedPairs,
  selectedPairs: reviewSeed.summary.selectedPairs,
  candidateResults: candidates.length,
}, null, 2));
