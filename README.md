# Drafts App Actions for Photographers

A collection of [Drafts](https://getdrafts.com/) actions that automate photography production workflows using Google Gemini AI.

**[Install from Drafts Directory](https://directory.getdrafts.com/g/23B)**

## Actions Included

### 1. NewCallSheet.scpt ("Call Sheet MacOS")
Creates a new call sheet from email threads in Mail.app.

**How it works:**
1. Select one or more emails in Mail.app
2. Run the action from Drafts
3. The script automatically finds all related thread messages (by subject)
4. A single Gemini call reconstructs the conversation chronologically AND extracts project details into a structured call sheet
5. A new draft is created with the call sheet, conversation history, and clickable links back to the source messages

**Features:**
- Automatically discovers thread messages by normalized subject
- Strips email prefixes (`Re:`, `Fwd:`) and bracket tags (`[EXTERNAL]`, `[EXT]`, etc.)
- Deduplicates messages by Message-ID and sorts chronologically
- Extracts text from PDF attachments via PDFKit (text layer only, no OCR) and includes it in the thread sent to the model
- Appends a `### SOURCE MESSAGES` section with `message://` links built deterministically — Message-IDs never pass through the model
- Single API call (system instruction + user content) for lower latency
- Caps at 50 messages to manage token limits

*(`CallSheetMacOS-old.scpt` is the previous version of this action, kept for reference.)*

### 2. UpdateCallSheet.scpt ("Update Call Sheet MacOS")
Updates an existing call sheet with new email information.

**How it works:**
1. Open an existing call sheet draft in Drafts
2. Select the new email(s) in Mail.app
3. Run the action
4. Gemini merges new facts into the call sheet and appends the new emails to the reconstructed thread
5. The draft is updated in-place

**Features:**
- Same PDF attachment extraction, dedupe, and chronological sorting as the create action
- The existing `### SOURCE MESSAGES` section is split off before the model call and re-appended afterward with links for the new messages, so links are never corrupted by the model
- Native networking via NSURLConnection (no curl; API key never appears in process arguments)

**Use case:** When you receive follow-up emails after creating the initial call sheet.

### 3. CallSheetiOS.js ("Call Sheet iOS")
iOS counterpart of the create action. Since iOS cannot script Mail, copy the email thread text to the clipboard, then run the action. Uses the same single-call prompt and produces the same call sheet format as the macOS action (minus source-message links, which require Mail access).

### 4. UpdateCallSheetiOS.js ("Update Call Sheet iOS")
iOS counterpart of the update action. Copy the new email text to the clipboard, open the call sheet draft, and run the action. Shows a clipboard preview before updating, and preserves any existing `### SOURCE MESSAGES` section without routing it through the model.

### 5. BlankCallSheet.js ("Blank Call Sheet")
Activates the `callsheet` workspace and loads the current draft in the editor. Pair with a Create Draft step using `BlankCallSheet.md` as the template.

### 6. CreateCaption.js ("Create Caption")
Generates photo metadata from shoot notes for Photo Mechanic ingestion.

**How it works:**
1. Create a draft with your shoot notes
2. Run the action
3. Gemini AI generates structured metadata
4. A new draft is created with the formatted output

**Output format:**
```
Slug: SubjectName
Title: Short Shoot Title  
Caption: {city:UC}, {state:UC} - {iptcmonthname:UC} {day0}: [description]...
Keywords: keyword1, keyword2, keyword3, ...
```

The caption uses Photo Mechanic template tags for automatic date/location insertion.

---

## Prerequisites

- **macOS** with Mail.app (for the AppleScript actions) or **iOS** (for the clipboard-based JavaScript actions)
- **[Drafts](https://getdrafts.com/)** app
- **Google Gemini API key**
  - macOS AppleScript actions read it from the **Keychain**
  - JavaScript actions read it from a **Drafts Credential** (you'll be prompted on first run)
- Active internet connection

## Setup

### 1. Store your Gemini API key in Keychain (macOS actions)

Open Terminal and run:
```bash
security add-generic-password -s "Gemini_API_Key" -a "$USER" -w "YOUR_API_KEY_HERE"
```

Replace `YOUR_API_KEY_HERE` with your actual [Gemini API key](https://aistudio.google.com/app/apikey).

### 2. Install the actions in Drafts

For AppleScript actions (`.scpt` files):
1. In Drafts, go to **Drafts → Settings → Actions**
2. Create a new Action
3. Add a step: **Script → AppleScript**
4. Copy the contents of the `.scpt` file into the script field

For JavaScript actions (`.js` files):
1. In Drafts, go to **Drafts → Settings → Actions**
2. Create a new Action
3. Add a step: **Script → Script**
4. Copy the contents of the `.js` file into the script field

### 3. Configure the Drafts Credential (JavaScript actions)

The JavaScript actions store the API key in Drafts credentials:
1. The first time you run one, Drafts will prompt for your API key
2. Or configure it in **Drafts → Settings → Credentials**

## Configuration

Edit these properties/constants at the top of each script:

| Property | Default | Description |
|----------|---------|-------------|
| `geminiAPIKeyName` | `"Gemini_API_Key"` | Keychain service name (macOS scripts) |
| `geminiModel` / `GEMINI_MODEL` | `"gemini-3.1-pro-preview"` (create, macOS) / `"gemini-3.1-flash-lite"` (updates, iOS) | Gemini model to use |
| `draftsTags` / `TAGS` | `callsheet` | Tags applied to new drafts |
| `maxMessagesPerThread` | `50` | Maximum messages to process |
| `maxPDFCharsPerAttachment` | `20000` | Cap on extracted PDF text per attachment (macOS) |
| `showAlerts` | `true` | Show error dialogs (macOS scripts) |
| `requestTimeoutSecs` / `HTTP_TIMEOUT` | `180` | Max seconds per Gemini API call |

## Call Sheet Format

Generated drafts contain the call sheet, a separator line of 36 dashes, the reconstructed email thread, and (on macOS) a source-links section:

| Section | Description |
|---------|-------------|
| **Location** | Photography location, address, start time |
| **Project Description** | Key objectives, scope, style, goals (incl. NYTimes Assignment ID) |
| **Team and Roles** | Team members, subjects, and their roles |
| **Client Information** | Client name, contacts, agency details |
| **Project Timeline** | Deadlines, shoot dates, delivery timelines |
| **Deliverables** | Required outputs with quantity and format |
| **Budget** | All financial details, quotes, rates |
| *(separator)* | Reconstructed thread: `**From:** Sender, Date, Time` entries |
| **Source Messages** | `message://` links to open the original emails in Mail (macOS only) |

## Error Handling

The scripts handle common errors:
- No email selected in Mail.app / empty clipboard
- API key not found in Keychain / Credential
- Gemini API errors (rate limits, invalid responses, content-filter blocks)
- Empty or malformed responses (including stripping stray code fences)

## License

MIT License - See [LICENSE](LICENSE) for details.

## Support

For issues or questions, please [open a GitHub issue](../../issues).
