const PRIMARY_MODEL = "models/gemini-3.1-flash-lite";

function extractJson(text) {
  if (!text) return "";
  let t = String(text).trim();
  t = t.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "");
  const first = t.indexOf("{");
  const last = t.lastIndexOf("}");
  if (first !== -1 && last !== -1 && last > first) return t.slice(first, last + 1);
  return t;
}

function oneLine(s) {
  return String(s || "").replace(/\s+/g, " ").trim();
}

function stripTrailingPeriod(s) {
  return oneLine(s).replace(/[.。]\s*$/, "");
}

function toCamelCaseWords(input) {
  let s = oneLine(input);
  s = s.replace(/[_|,]+/g, " ");
  s = s.replace(/[^A-Za-z0-9 ]+/g, " ").replace(/\s+/g, " ").trim();
  if (!s) return "";
  const words = s.split(" ").filter(Boolean).slice(0, 3);
  return words.map(w => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()).join("");
}

function sanitizeKeyword(k) {
  let s = String(k || "").trim();
  s = s.replace(/[{}]/g, "");
  s = s.replace(/^#+/, "");
  s = s.replace(/\s+/g, " ").replace(/[.,;:]+$/g, "").trim();
  return s;
}

function normalizeKeywords(val) {
  let arr = [];
  if (Array.isArray(val)) {
    arr = val;
  } else if (typeof val === "string") {
    arr = val.split(/[,;\n|]+/);
  }
  const seen = {};
  const out = [];
  for (let item of arr) {
    const s = sanitizeKeyword(item);
    if (!s) continue;
    const key = s.toLowerCase();
    if (seen[key]) continue;
    seen[key] = true;
    out.push(s);
    if (out.length >= 20) break;
  }
  return out;
}

let f = () => {
  const draftContent = draft.content;
  if (!draftContent || draftContent.trim().length === 0) {
    alert("Empty Draft\n\nThere is no text to process.");
    return false;
  }

  draft.update();

  const systemInstruction =
    "You are generating metadata for an editorial photo shoot based on the shoot notes.\n" +
    "Return ONLY valid JSON (no code fences, no extra text) with exactly these keys:\n" +
    '  slug_words: string (1–3 words naming the subject; no punctuation)\n' +
    '  title: string (short shoot title)\n' +
    '  shortDescription: string (present-tense clause that fits after \": \" and before \" on {iptcmonthname} {day0}\")\n' +
    "  longDescription: string (1–2 sentences expanding context; do NOT include date; do NOT include city/state; do NOT include any {tags}; do NOT include photographer credit; do NOT end with a period)\n" +
    "  keywords: array of strings (6–12 useful keywords for photo ingest/search; include proper nouns if present in notes; avoid generic words like \"photo\"; do NOT include any {tags})\n" +
    "If details are missing, stay accurate and generic rather than guessing.";

  const combinedPrompt =
    systemInstruction + "\n\n--- Shoot Notes ---\n" + draftContent;

  let ai = new GoogleAI();
  ai.apiVersion = "v1beta";

  let raw = "";
  try {
    raw = ai.quickPrompt(combinedPrompt, PRIMARY_MODEL);
    if (!raw || raw.trim().length === 0) throw new Error("Empty response received.");
  } catch (error) {
    alert("AI Error\n\nGemini failed: " + (ai.lastError || error));
    return false;
  }

  let data;
  try {
    const jsonText = extractJson(raw);
    data = JSON.parse(jsonText);
  } catch (error) {
    alert("Parse Error\n\nGemini returned something that wasn't valid JSON.\n\nResponse was:\n" + raw);
    return false;
  }

  const slugWords = Array.isArray(data.slug_words) ? data.slug_words.join(" ") : data.slug_words;
  const slug = toCamelCaseWords(slugWords);
  const title = oneLine(data.title);
  const shortDesc = stripTrailingPeriod(data.shortDescription).replace(/[{}]/g, "");
  const longDesc = stripTrailingPeriod(data.longDescription).replace(/[{}]/g, "");

  if (!slug || !title || !shortDesc || !longDesc) {
    alert("Missing Fields\n\nGemini did not return all required fields. Got:\n" + JSON.stringify(data, null, 2));
    return false;
  }

  const keywordsArr = normalizeKeywords(data.keywords);
  const keywordsLine = keywordsArr.length ? keywordsArr.join(", ") : "";

  const caption =
    `{city:UC}, {state:UC} - {iptcmonthname:UC} {day0}: ` +
    `${shortDesc} on {iptcmonthname} {day0}, {iptcyear4} in {city}, {state}. ` +
    `${longDesc}. ( David Degner / www.DavidDegner.com )`;

  const output =
    `Slug: ${slug}\n` +
    `Title: ${title}\n` +
    `Caption: ${caption}\n` +
    `Keywords: ${keywordsLine}`;

  let newDraft = new Draft();
  newDraft.content = output;
  newDraft.update();
  editor.load(newDraft);

  return true;
};

if (!f()) {
  context.cancel();
}