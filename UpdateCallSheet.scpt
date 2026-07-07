use framework "Foundation"
use framework "Quartz"
use scripting additions
-- =====================================================
-- Drafts: Mail → Update Call Sheet (MacOS)
-- =====================================================
-- Notes for Drafts AppleScript actions (macOS):
--  • Drafts calls `on execute(d)` automatically. The passed `d` is a read-only
--    record of the CURRENT draft (the call sheet being updated).
--  • Networking uses NSURLConnection sendSynchronousRequest (works inside Drafts'
--    host; NSURLSession's script-object delegate does not fire reliably there).
--  • Selected messages are read once into records, then deduped and sorted with no Mail calls.
--  • PDF attachments are extracted to text via PDFKit (text layer only, no OCR) and
--    folded into each message body before the emails are sent to the model.
--  • The existing "### SOURCE MESSAGES" section is split off before the model call and
--    re-appended afterward with links for the new messages, so message:// URLs are
--    never routed through the model (which would corrupt the Message-IDs).
--  • Writeback uses the drafts:// replaceRange URL scheme; Drafts' AppleScript
--    dictionary can create drafts but not modify existing ones.
-- =====================================================
-- *** USER SETTINGS ***
property geminiAPIKeyName : "Gemini_API_Key" -- Keychain service name for the Gemini API key
property geminiModel : "gemini-3.1-flash-lite" -- Model for call sheet updates
property maxMessagesPerThread : 50 -- Cap to limit token/latency
property maxPDFCharsPerAttachment : 20000 -- Cap extracted PDF text per attachment
property showAlerts : true -- Set false to suppress display alerts when running from Drafts
property requestTimeoutSecs : 180 -- Max seconds per Gemini API call
-- System instruction: defines the model's role and output constraints.
property systemInstruction : "You are a production assistant for photographer David Degner. You update existing call sheets with new information from email threads.
<rules>
- Extract ONLY facts explicitly stated in the new emails. Never infer or fabricate details.
- Preserve the existing call sheet's headings, structure, formatting, and spacing exactly.
- Only change a field when the new emails provide a definitive update; otherwise leave it as-is.
- Fill in empty sections when the new emails provide the missing information.
- Omit conversational pleasantries, sign-offs, and email signatures.
- Use markdown formatting only. Do not use HTML.
- Do not wrap your output in code fences (no ```markdown or ``` delimiters).
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
</output_format>"
-- User prompt template: context-first, task-last (per Gemini best practices for long context)
property userPromptPartA : "Update the following existing call sheet using the new emails, per your instructions.
<existing_call_sheet>"
property userPromptPartB : "</existing_call_sheet>
<new_emails>"
property userPromptPartC : "</new_emails>
Produce the complete updated document now."
-- =============================
-- Utility helpers
-- =============================
on showAlert(t, m)
	if showAlerts then
		display alert t message m buttons {"OK"} default button "OK"
	end if
end showAlert
on replace_chars(theText, searchString, replacementString)
	set AppleScript's text item delimiters to searchString
	set theItems to text items of theText
	set AppleScript's text item delimiters to replacementString
	set theText to theItems as string
	set AppleScript's text item delimiters to ""
	return theText
end replace_chars
on trim(someText)
	set nsText to current application's NSString's stringWithString:someText
	set trimmedText to nsText's stringByTrimmingCharactersInSet:(current application's NSCharacterSet's whitespaceAndNewlineCharacterSet())
	return trimmedText as string
end trim
on stripCodeFences(someText)
	-- Strip leading ```markdown or ``` and trailing ```
	set t to my trim(someText)
	if t begins with "```" then
		-- Find end of first line (the opening fence)
		set fenceEnd to offset of linefeed in t
		if fenceEnd > 0 then
			set t to text (fenceEnd + 1) thru -1 of t
		end if
	end if
	if t ends with "```" then
		set t to text 1 thru -4 of t
	end if
	return my trim(t)
end stripCodeFences
on getAPIKeyFromKeychain(keyName)
	try
		set apiKey to do shell script "security find-generic-password -w -s " & quoted form of keyName
		return apiKey
	on error
		return missing value
	end try
end getAPIKeyFromKeychain
-- Make a sender/date string safe to use as Markdown link text
on sanitizeLinkLabel(someText)
	set t to my replace_chars(someText, "[", "(")
	set t to my replace_chars(t, "]", ")")
	set t to my replace_chars(t, "<", "")
	set t to my replace_chars(t, ">", "")
	return t
end sanitizeLinkLabel
-- Build a Markdown-safe message:// URL from a raw Message-ID
on messageURL(mid)
	set nsID to current application's NSString's stringWithString:(mid as text)
	set allowedChars to current application's NSCharacterSet's characterSetWithCharactersInString:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~@"
	set encID to (nsID's stringByAddingPercentEncodingWithAllowedCharacters:allowedChars) as text
	return "message://%3c" & encID & "%3e"
end messageURL
-- Percent-encode text for use as a drafts:// URL query value
on encodeURIComponent(t)
	set ns to current application's NSString's stringWithString:t
	set allowed to current application's NSCharacterSet's URLQueryAllowedCharacterSet()
	set m to allowed's mutableCopy()
	m's removeCharactersInString:"&=?+" -- conservative for query values
	set enc to ns's stringByAddingPercentEncodingWithAllowedCharacters:m
	return enc as text
end encodeURIComponent
on getUUIDFromRecord(r)
	try
		return |uuid| of r
	on error
		try
			return uuid of r
		on error
			return ""
		end try
	end try
end getUUIDFromRecord
-- =============================
-- PDF attachment extraction (PDFKit text layer; no OCR)
-- =============================
on pdfFileToText(posixPath)
	set theURL to current application's NSURL's fileURLWithPath:posixPath
	set pdfDoc to current application's PDFDocument's alloc()'s initWithURL:theURL
	if pdfDoc is missing value then return "" -- unreadable or encrypted
	set theString to pdfDoc's |string|()
	if theString is missing value then return "" -- no embedded text layer (scanned image)
	return (theString as text)
end pdfFileToText
on extractPDFText(theMessage)
	set collectedText to ""
	tell application "Mail"
		set atts to mail attachments of theMessage
	end tell
	repeat with a in atts
		tell application "Mail"
			set aName to (name of a)
			set isDown to (downloaded of a)
			set aMime to ""
			try
				set aMime to (MIME type of a)
			end try
		end tell
		set isPDF to (aMime is "application/pdf") or (aName ends with ".pdf") or (aName ends with ".PDF")
		if isPDF then
			try
				if not isDown then error "attachment not downloaded"
				set tmpPath to (POSIX path of (path to temporary items)) & "callsheet_" & (do shell script "uuidgen") & ".pdf"
				tell application "Mail"
					save a in (POSIX file tmpPath)
				end tell
				set t to my pdfFileToText(tmpPath)
				do shell script "rm -f " & quoted form of tmpPath
				set t to my trim(t)
				if (count of t) > maxPDFCharsPerAttachment then
					set t to (text 1 thru maxPDFCharsPerAttachment of t) & linefeed & "[...PDF text truncated...]"
				end if
				if t is not "" then
					set collectedText to collectedText & "----- PDF ATTACHMENT: " & aName & " -----" & linefeed & t & linefeed & linefeed
				end if
			on error
				-- not downloaded, encrypted, or unreadable: skip silently
			end try
		end if
	end repeat
	return collectedText
end extractPDFText
-- =============================
-- Read messages once, dedupe by Message-ID in the same pass.
-- Returns a list of records; no further Mail calls are needed after this.
-- =============================
on collectMessageData(messageList)
	set recordList to {}
	set seenIDs to {}
	tell application "Mail"
		repeat with m in messageList
			set mid to message id of m
			if seenIDs does not contain mid then
				set end of seenIDs to mid
				set theSender to sender of m
				set theSubject to subject of m
				set theDate to date received of m
				set theBody to content of m
				set pdfText to my extractPDFText(m)
				if pdfText is not "" then set theBody to theBody & linefeed & linefeed & pdfText
				set end of recordList to {msgID:mid, dateVal:theDate, theSender:theSender, theSubject:theSubject, theBody:theBody}
			end if
		end repeat
	end tell
	return recordList
end collectMessageData
-- Insertion sort, ascending by date. Pure AppleScript, no Apple events.
-- Uses an explicit nested test (not `and`) so item j is never read when j < 1.
on sortRecordsByDate(recordList)
	set n to count of recordList
	if n < 2 then return recordList
	repeat with i from 2 to n
		set curRec to item i of recordList
		set curDate to dateVal of curRec
		set j to i - 1
		set placed to false
		repeat while j ≥ 1 and (not placed)
			if (dateVal of (item j of recordList)) > curDate then
				set item (j + 1) of recordList to item j of recordList
				set j to j - 1
			else
				set placed to true
			end if
		end repeat
		set item (j + 1) of recordList to curRec
	end repeat
	return recordList
end sortRecordsByDate
-- =============================
-- Gemini call via NSURLConnection (synchronous, sandbox-safe, no curl dependency)
-- =============================
on callGeminiAPI(apiKey, sysInstruction, promptText, modelName)
	-- Build request JSON with Cocoa (safe escaping)
	set dict to current application's NSMutableDictionary's dictionary()
	-- System instruction (separate from user content)
	set sysPartsArr to current application's NSMutableArray's array()
	set sysPartDict to current application's NSMutableDictionary's dictionary()
	sysPartDict's setObject:sysInstruction forKey:"text"
	sysPartsArr's addObject:sysPartDict
	set sysDict to current application's NSMutableDictionary's dictionary()
	sysDict's setObject:sysPartsArr forKey:"parts"
	dict's setObject:sysDict forKey:"system_instruction"
	-- User content
	set contentsArr to current application's NSMutableArray's array()
	set partsArr to current application's NSMutableArray's array()
	set partDict to current application's NSMutableDictionary's dictionary()
	partDict's setObject:promptText forKey:"text"
	partsArr's addObject:partDict
	set contentDict to current application's NSMutableDictionary's dictionary()
	contentDict's setObject:"user" forKey:"role"
	contentDict's setObject:partsArr forKey:"parts"
	contentsArr's addObject:contentDict
	dict's setObject:contentsArr forKey:"contents"
	-- Generation config
	set genCfg to current application's NSMutableDictionary's dictionary()
	genCfg's setObject:(current application's NSNumber's numberWithDouble:1.0) forKey:"temperature"
	genCfg's setObject:(current application's NSNumber's numberWithInteger:16384) forKey:"maxOutputTokens"
	dict's setObject:genCfg forKey:"generationConfig"
	set jsonData to current application's NSJSONSerialization's dataWithJSONObject:dict options:0 |error|:(missing value)
	-- Build NSURLRequest
	set endpointStr to "https://generativelanguage.googleapis.com/v1beta/models/" & modelName & ":generateContent"
	set reqURL to current application's NSURL's URLWithString:endpointStr
	set urlRequest to current application's NSMutableURLRequest's requestWithURL:reqURL
	urlRequest's setHTTPMethod:"POST"
	urlRequest's setHTTPBody:jsonData
	urlRequest's setValue:"application/json" forHTTPHeaderField:"Content-Type"
	urlRequest's setValue:apiKey forHTTPHeaderField:"x-goog-api-key"
	urlRequest's setTimeoutInterval:requestTimeoutSecs
	-- Synchronous send via NSURLConnection (native macOS networking, works inside Drafts' host)
	set {respData, urlResponse, respError} to current application's NSURLConnection's sendSynchronousRequest:urlRequest returningResponse:(reference) |error|:(reference)
	if respError is not missing value then
		set errDesc to (respError's localizedDescription()) as text
		my showAlert("Network Error", "Failed to reach Gemini API:" & linefeed & errDesc)
		return {success:false, body:""}
	end if
	if respData is missing value then
		my showAlert("Network Error", "Gemini API returned no data.")
		return {success:false, body:""}
	end if
	-- Parse response JSON
	set respObj to current application's NSJSONSerialization's JSONObjectWithData:respData options:0 |error|:(missing value)
	if respObj is missing value then
		set rawResp to (current application's NSString's alloc()'s initWithData:respData encoding:(current application's NSUTF8StringEncoding)) as text
		my showAlert("Gemini Error", "Could not parse API response as JSON." & linefeed & linefeed & "Raw response:" & linefeed & rawResp)
		return {success:false, body:""}
	end if
	-- Check for API-level error object
	set errObj to respObj's objectForKey:"error"
	if errObj is not missing value then
		set errMessage to (errObj's objectForKey:"message") as text
		my showAlert("Gemini API Error", errMessage)
		return {success:false, body:""}
	end if
	set candidates to respObj's objectForKey:"candidates"
	if (candidates = missing value) or ((candidates's |count|()) = 0) then
		set rawResp to (current application's NSString's alloc()'s initWithData:respData encoding:(current application's NSUTF8StringEncoding)) as text
		my showAlert("Gemini Error", "Gemini returned no candidates." & linefeed & linefeed & "Response:" & linefeed & rawResp)
		return {success:false, body:""}
	end if
	set firstCand to candidates's objectAtIndex:0
	-- Check for content-filtering block (finishReason != "STOP")
	set finishReason to firstCand's objectForKey:"finishReason"
	if finishReason is not missing value then
		set frText to finishReason as text
		if frText is not "STOP" and frText is not "MAX_TOKENS" then
			my showAlert("Gemini Blocked", "Response was blocked by content filter." & linefeed & "Reason: " & frText)
			return {success:false, body:""}
		end if
	end if
	set contentDict2 to firstCand's objectForKey:"content"
	if contentDict2 is missing value then
		my showAlert("Gemini Error", "Gemini candidate has no content object.")
		return {success:false, body:""}
	end if
	set partsArray2 to contentDict2's objectForKey:"parts"
	if (partsArray2 is missing value) or ((partsArray2's |count|()) = 0) then
		my showAlert("Gemini Error", "Gemini returned no text parts.")
		return {success:false, body:""}
	end if
	set outText to ""
	repeat with i from 0 to ((partsArray2's |count|()) - 1)
		set p to (partsArray2's objectAtIndex:i)
		set t to p's objectForKey:"text"
		if t is not missing value then set outText to outText & (t as text)
	end repeat
	-- Guard against valid JSON but empty actual text
	if (my trim(outText)) is "" then
		my showAlert("Gemini Error", "Gemini returned parts but no text content." & linefeed & linefeed & "This may indicate the model filtered the response or changed its output format.")
		return {success:false, body:""}
	end if
	return {success:true, body:outText}
end callGeminiAPI
-- =============================
-- Drafts Action Entry Point
-- =============================
on execute(d)
	try
		-- Current draft content + uuid from the Drafts-supplied record
		set callsheetText to ""
		try
			set callsheetText to (content of d)
		end try
		if (my trim(callsheetText)) is "" then
			my showAlert("No Call Sheet", "The current draft is empty. Open the call sheet you want to update, then run again.")
			return ""
		end if
		set theUUID to my getUUIDFromRecord(d)
		if theUUID is "" then
			my showAlert("Error", "Could not read the current draft UUID.")
			return ""
		end if
		-- Split off the SOURCE MESSAGES section so its links never pass through the model
		set srcHeader to "### SOURCE MESSAGES"
		set mainText to callsheetText
		set sourceSection to ""
		set hPos to offset of srcHeader in callsheetText
		if hPos > 1 then
			set mainText to my trim(text 1 thru (hPos - 1) of callsheetText)
			set sourceSection to my trim(text hPos thru -1 of callsheetText)
		else if hPos is 1 then
			set mainText to ""
			set sourceSection to my trim(callsheetText)
		end if
		-- Gather selected Mail messages (only the selection; no thread expansion for updates)
		set sel to {}
		with timeout of 600 seconds
			tell application "Mail"
				if not (exists message viewer 1) then
					my showAlert("No message viewer", "Open Mail and select the new message(s).")
					return ""
				end if
				set sel to (selected messages of message viewer 1)
				if sel is {} then
					my showAlert("No email selected", "Select the new email(s) in Mail, then run again.")
					return ""
				end if
			end tell
		end timeout
		-- Read each message once (deduped, with PDF text), then sort with no further Mail calls
		set msgRecords to my collectMessageData(sel)
		set msgRecords to my sortRecordsByDate(msgRecords)
		-- Cap to the most recent N to keep prompts manageable
		set totalCount to (count of msgRecords)
		if totalCount > maxMessagesPerThread then
			set startIndex to (totalCount - maxMessagesPerThread + 1)
			set msgRecords to items startIndex thru totalCount of msgRecords
		end if
		-- Build the new-email text and Markdown-safe links for messages not already linked
		set newEmailText to ""
		set sourceLinks to ""
		set recCount to (count of msgRecords)
		repeat with k from 1 to recCount
			set rec to item k of msgRecords
			set theDate to dateVal of rec
			set ds to (date string of theDate)
			set ts to (time string of theDate)
			set newEmailText to newEmailText & "From: " & (theSender of rec) & " / Subject: " & (theSubject of rec) & " / Date: " & ds & " " & ts & linefeed & (theBody of rec) & linefeed & linefeed & "---" & linefeed & linefeed
			set linkURL to my messageURL(msgID of rec)
			if sourceSection does not contain linkURL then
				set lbl to my sanitizeLinkLabel((theSender of rec) & ", " & ds & " " & ts)
				set sourceLinks to sourceLinks & "- [" & lbl & "](" & linkURL & ")" & linefeed
			end if
		end repeat
		-- Validate we actually got email content
		if (my trim(newEmailText)) is "" then
			my showAlert("Empty Thread", "No email content could be extracted from the selected messages.")
			return ""
		end if
		-- Build the user prompt: context first, instruction last
		set fullPrompt to userPromptPartA & linefeed & mainText & linefeed & userPromptPartB & linefeed & newEmailText & linefeed & userPromptPartC
		set geminiAPIKey to my getAPIKeyFromKeychain(geminiAPIKeyName)
		if geminiAPIKey is missing value then
			my showAlert("API Key Not Found", "Store your Gemini API Key in Keychain with the service name '" & geminiAPIKeyName & "'.")
			return ""
		end if
		-- Single API call
		set apiResult to my callGeminiAPI(geminiAPIKey, systemInstruction, fullPrompt, geminiModel)
		if success of apiResult is false then return ""
		-- Strip code fences if the model wrapped its output, normalize line endings
		set cleanOutput to my stripCodeFences(body of apiResult)
		set updatedText to my replace_chars(cleanOutput, return, linefeed)
		-- Re-append the deterministic source links (never routed through the model)
		if sourceSection is not "" then
			set updatedText to updatedText & linefeed & linefeed & sourceSection & linefeed
			if (my trim(sourceLinks)) is not "" then set updatedText to updatedText & sourceLinks
		else if (my trim(sourceLinks)) is not "" then
			set updatedText to updatedText & linefeed & linefeed & srcHeader & linefeed & linefeed & sourceLinks
		end if
		-- Write back to THIS draft via the Drafts URL scheme (replaces the full content)
		set encodedText to my encodeURIComponent(updatedText)
		set L to (length of callsheetText)
		if L < 0 then set L to 0
		set u to "drafts://x-callback-url/replaceRange?uuid=" & theUUID & "&text=" & encodedText & "&start=0&length=" & (L as text)
		open location u
		return ""
	on error errMsg number errNum
		my showAlert("Error", ("An error occurred: " & errMsg & " (" & errNum & ")"))
		return ""
	end try
end execute
