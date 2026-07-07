// Drafts JavaScript Action
// Clipboard (email thread text) → Gemini (single call: call sheet + reconstructed thread) → New Draft tagged "callsheet"
// iOS counterpart of the "Call Sheet MacOS" AppleScript action. Input comes from the
// clipboard (iOS cannot script Mail); the prompts and output format match the macOS action.

// -----------------------------
// USER SETTINGS
// -----------------------------
const GEMINI_MODEL = "gemini-3.1-flash-lite";
const TAGS = ["callsheet"];

const MAX_SOURCE_CHARS = 120000;   // keep the last N chars from clipboard
const TEMPERATURE = 1.0;           // 1.0 is recommended for Gemini 3
const MAX_OUTPUT_TOKENS = 16384;
const HTTP_TIMEOUT = 180;          // seconds

// System instruction: defines the model's role and output constraints (matches macOS action).
const SYSTEM_INSTRUCTION = `You are a production assistant for photographer David Degner. You process raw email threads into structured call sheets.
<rules>
- Extract ONLY facts explicitly stated in the email thread. Never infer or fabricate details.
- Omit conversational pleasantries, sign-offs, and email signatures.
- Use markdown formatting only. Do not use HTML.
- Do not wrap your output in code fences (no \`\`\`markdown or \`\`\` delimiters).
- If a section has no relevant information in the thread, include only the heading with no content below it.
</rules>
<output_format>
Your response must contain exactly two sections separated by a line of 36 dashes (------------------------------------).
The first line must be: # YYYYMMDD - {project-title}
If the shoot date is unknown, use XXXXXXXXX in place of YYYYMMDD.
Then include these markdown headings in order, each as ###:
### LOCATION
The photography location or client address and start time.
### PROJECT DESCRIPTION
Key objectives, scope, style, goals, or focus areas.  If a NYTimes assignment include the Assignment ID here.
### TEAM AND ROLES
All mentioned team members, subjects, and their roles.
### CLIENT INFORMATION
Client/company name, main contact (and role if mentioned), contact details (email, phone) without labels. Include agency name and contact if involved.
### PROJECT TIMELINE
Labeled relevant dates: deadlines, shoot dates, delivery timelines.
### DELIVERABLES
Required outputs (photos, videos) with quantity, format, and settings.
### BUDGET
All mentions of budgets, costs, fees, pricing, estimates, quotes, rates, and monetary values.
After the separator line, present the emails in correct chronological order with redundant quoted text and signatures removed.
Format each message as:
**From:** Sender Name, Date, Time
Message content
---
</output_format>`;

// User prompt template: context-first, task-last (per Gemini best practices for long context)
const USER_PROMPT_INTRO = `Process the following raw email thread into a call sheet and reconstructed thread per your instructions.
<email_thread>`;

const USER_PROMPT_OUTRO = `</email_thread>
Produce the call sheet followed by the separator line and reconstructed thread now.`;

// -----------------------------
// HELPERS
// -----------------------------
function normalizeNewlines(s) {
  return (s || "").replace(/\r\n/g, "\n").replace(/\r/g, "\n");
}

function tailChars(s, maxChars) {
  s = s || "";
  if (s.length <= maxChars) return s;
  return s.slice(s.length - maxChars);
}

function stripCodeFences(s) {
  // Strip leading ```markdown or ``` and trailing ```
  let t = (s || "").trim();
  if (t.startsWith("```")) {
    const nl = t.indexOf("\n");
    if (nl > -1) t = t.slice(nl + 1);
  }
  if (t.endsWith("```")) t = t.slice(0, -3);
  return t.trim();
}

function showAlert(title, message) {
  // Title + message dialog using Prompt (since app.alert is not a thing)
  const p = Prompt.create();
  p.title = title || "Notice";
  p.message = message || "";
  p.isCancellable = false;
  p.addButton("OK");
  p.show();
}

function getSourceTextFromClipboard() {
  // Use Drafts system clipboard API
  let t = app.getClipboard() || "";
  t = normalizeNewlines(t).trim();
  return tailChars(t, MAX_SOURCE_CHARS);
}

function getGeminiApiKey() {
  const cred = Credential.create("Gemini API Key");
  cred.addPasswordField("apiKey", "Gemini API Key", "");
  if (!cred.authorize()) {
    showAlert("Missing API Key", "Gemini API key not provided/authorized.");
    return null;
  }
  const key = (cred.getValue("apiKey") || "").trim();
  if (!key) {
    showAlert("Missing API Key", "Gemini API key is empty.");
    return null;
  }
  return key;
}

function extractGeminiText(respJson) {
  const c0 = respJson && respJson.candidates && respJson.candidates[0];
  const parts = c0 && c0.content && Array.isArray(c0.content.parts) ? c0.content.parts : null;
  if (!parts || parts.length === 0) return null;

  const text = parts
    .map(p => (p && typeof p.text === "string" ? p.text : ""))
    .join("");

  return text && text.trim().length ? text : null;
}

function callGemini(apiKey, systemInstruction, promptText) {
  const endpoint =
    `https://generativelanguage.googleapis.com/v1beta/models/` +
    `${encodeURIComponent(GEMINI_MODEL)}:generateContent`;

  const payload = {
    systemInstruction: {
      parts: [{ text: systemInstruction }],
    },
    contents: [
      {
        role: "user",
        parts: [{ text: promptText }],
      },
    ],
    generationConfig: {
      temperature: TEMPERATURE,
      maxOutputTokens: MAX_OUTPUT_TOKENS,
    },
  };

  const http = HTTP.create();
  http.timeout = HTTP_TIMEOUT;

  const resp = http.request({
    url: endpoint,
    method: "POST",
    encoding: "json",            // let Drafts encode payload as JSON
    data: payload,               // IMPORTANT: pass object, not JSON.stringify(...)
    headers: {
      "x-goog-api-key": apiKey,
      "Content-Type": "application/json",
    },
  });

  if (!resp || resp.success !== true) {
    const status = resp ? resp.statusCode : "(no response)";
    const err = resp ? (resp.error || "") : "";
    const body = resp ? (resp.responseText || "") : "";
    showAlert("Gemini API Error", `Request failed.\nStatus: ${status}\n${err ? "\n" + err : ""}\n\n${body}`);
    return null;
  }

  let obj;
  try {
    obj = JSON.parse(resp.responseText);
  } catch (e) {
    showAlert("Gemini API Error", "Could not parse JSON response.\n\n" + (resp.responseText || ""));
    return null;
  }

  if (obj && obj.error) {
    showAlert("Gemini API Error", JSON.stringify(obj.error, null, 2));
    return null;
  }

  // Check for content-filtering block (finishReason != "STOP")
  const c0 = obj && obj.candidates && obj.candidates[0];
  const finishReason = c0 && c0.finishReason;
  if (finishReason && finishReason !== "STOP" && finishReason !== "MAX_TOKENS") {
    showAlert("Gemini Blocked", "Response was blocked by content filter.\nReason: " + finishReason);
    return null;
  }

  const text = extractGeminiText(obj);
  if (!text) {
    showAlert("Gemini API Error", "No usable text returned.\n\n" + (resp.responseText || ""));
    return null;
  }

  return text;
}

// -----------------------------
// MAIN
// -----------------------------
(function main() {
  try {
    const sourceText = getSourceTextFromClipboard();
    if (!sourceText) {
      showAlert("Clipboard Empty", "Copy the email/thread text to the clipboard, then run this action again.");
      return;
    }

    const apiKey = getGeminiApiKey();
    if (!apiKey) return;

    // Single API call: system instruction handles role/format, user content has the thread
    const fullPrompt = `${USER_PROMPT_INTRO}\n${sourceText}\n${USER_PROMPT_OUTRO}`;
    const output = callGemini(apiKey, SYSTEM_INSTRUCTION, fullPrompt);
    if (!output) return;

    const fullContent = stripCodeFences(normalizeNewlines(output));
    if (!fullContent) {
      showAlert("Empty Output", "Gemini returned empty text.");
      return;
    }

    // Create + tag + save
    const out = Draft.create();
    out.content = fullContent;
    TAGS.forEach(t => out.addTag(t));
    out.update();

    // Open the new draft in the editor
    editor.load(out);
  } catch (err) {
    showAlert("Error", String(err));
  }
})();
