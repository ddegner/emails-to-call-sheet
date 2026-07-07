// Drafts JavaScript Action
// Update CURRENT call sheet draft using NEW email thread text from CLIPBOARD via Gemini.
// iOS counterpart of the "Update Call Sheet MacOS" AppleScript action. The existing
// "### SOURCE MESSAGES" section is split off before the model call and re-appended
// afterward, so message:// links are never routed through the model.

// -----------------------------
// USER SETTINGS
// -----------------------------
const GEMINI_MODEL = "gemini-3.1-flash-lite";
const TEMPERATURE = 1.0;           // 1.0 is recommended for Gemini 3
const MAX_OUTPUT_TOKENS = 16384;
const HTTP_TIMEOUT = 180;          // seconds

// If the clipboard is huge, keep the most recent tail
const MAX_EMAIL_CHARS = 120000;

const SOURCE_HEADER = "### SOURCE MESSAGES";

// System instruction: defines the model's role and output constraints (matches macOS update action).
const SYSTEM_INSTRUCTION = `You are a production assistant for photographer David Degner. You update existing call sheets with new information from email threads.
<rules>
- Extract ONLY facts explicitly stated in the new emails. Never infer or fabricate details.
- Preserve the existing call sheet's headings, structure, formatting, and spacing exactly.
- Only change a field when the new emails provide a definitive update; otherwise leave it as-is.
- Fill in empty sections when the new emails provide the missing information.
- Omit conversational pleasantries, sign-offs, and email signatures.
- Use markdown formatting only. Do not use HTML.
- Do not wrap your output in code fences (no \`\`\`markdown or \`\`\` delimiters).
- Output ONLY the updated document; no commentary before or after.
</rules>
<output_format>
The document contains a call sheet, then a separator line of 36 dashes (------------------------------------), then the reconstructed email thread.
Above the separator: update the call sheet sections with new facts from the new emails.
Below the separator: merge the new emails into the thread in correct chronological order (oldest first), skipping any message already present, with redundant quoted text and signatures removed.
Format each merged message as:
**From:** Sender Name, Date, Time
Message content
---
If the existing document uses a different structure, preserve that structure and merge the new emails into its email list section instead.
</output_format>`;

// User prompt template: context-first, task-last (per Gemini best practices for long context)
const USER_PROMPT_PART_A = `Update the following existing call sheet using the new emails, per your instructions.
<existing_call_sheet>`;

const USER_PROMPT_PART_B = `</existing_call_sheet>
<new_emails>`;

const USER_PROMPT_PART_C = `</new_emails>
Produce the complete updated document now.`;

// -----------------------------
// UI HELPERS
// -----------------------------
function showAlert(title, message) {
  const p = Prompt.create();
  p.title = title || "Notice";
  p.message = message || "";
  p.isCancellable = false;
  p.addButton("OK");
  p.show();
}

function showConfirm(title, message, okLabel) {
  const p = Prompt.create();
  p.title = title || "Confirm";
  p.message = message || "";
  p.isCancellable = true;
  p.addButton(okLabel || "OK");
  const r = p.show();
  return r && p.buttonPressed === (okLabel || "OK");
}

// -----------------------------
// TEXT HELPERS
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

function getClipboardText() {
  let t = app.getClipboard() || "";
  t = normalizeNewlines(t).trim();
  return tailChars(t, MAX_EMAIL_CHARS);
}

// -----------------------------
// CREDENTIALS
// -----------------------------
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

// -----------------------------
// GEMINI CALL
// -----------------------------
function extractGeminiText(respJson) {
  const c0 = respJson && respJson.candidates && respJson.candidates[0];
  const parts = c0 && c0.content && Array.isArray(c0.content.parts) ? c0.content.parts : null;
  if (!parts || parts.length === 0) return null;

  const text = parts
    .map((p) => (p && typeof p.text === "string" ? p.text : ""))
    .join("");

  return text && text.trim().length ? text : null;
}

function callGemini(apiKey, systemInstruction, promptText) {
  const endpoint =
    "https://generativelanguage.googleapis.com/v1beta/models/" +
    encodeURIComponent(GEMINI_MODEL) +
    ":generateContent";

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
    encoding: "json",
    data: payload, // IMPORTANT: object, not JSON.stringify
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
    // Current call sheet is the CURRENT draft content
    const existingCallsheet = normalizeNewlines(draft.content || "").trim();
    if (!existingCallsheet) {
      showAlert("No Call Sheet", "The current draft is empty. Open the call sheet draft you want to update, then run again.");
      return;
    }

    // Split off the SOURCE MESSAGES section so its links never pass through the model
    let mainText = existingCallsheet;
    let sourceSection = "";
    const idx = existingCallsheet.indexOf(SOURCE_HEADER);
    if (idx !== -1) {
      mainText = existingCallsheet.slice(0, idx).trim();
      sourceSection = existingCallsheet.slice(idx).trim();
    }

    // New emails always from clipboard
    const newEmails = getClipboardText();
    if (!newEmails) {
      showAlert("Clipboard Empty", "Copy the NEW email thread text to the clipboard, then run this action again.");
      return;
    }

    // Optional: quick sanity check (prevents overwriting with wrong clipboard)
    const preview = newEmails.slice(0, 400) + (newEmails.length > 400 ? "\n…(truncated preview)…" : "");
    const ok = showConfirm("Update Call Sheet?", "Clipboard preview:\n\n" + preview, "Update");
    if (!ok) return;

    const apiKey = getGeminiApiKey();
    if (!apiKey) return;

    const promptText =
      USER_PROMPT_PART_A + "\n" + mainText + "\n" +
      USER_PROMPT_PART_B + "\n" + newEmails + "\n" +
      USER_PROMPT_PART_C;

    const updatedText = callGemini(apiKey, SYSTEM_INSTRUCTION, promptText);
    if (!updatedText) return;

    let finalText = stripCodeFences(normalizeNewlines(updatedText));
    if (!finalText) {
      showAlert("Empty Output", "Gemini returned empty text.");
      return;
    }

    // Re-append the SOURCE MESSAGES section deterministically (never routed through the model)
    if (sourceSection) {
      finalText = finalText + "\n\n" + sourceSection;
    }

    // Update THIS draft in place
    draft.content = finalText;
    draft.update();

    // Keep editor on this draft (optional, but nice)
    editor.load(draft);
  } catch (err) {
    showAlert("Error", String(err));
  }
})();
