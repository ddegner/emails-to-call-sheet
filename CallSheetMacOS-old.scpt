use framework "Foundation"
use scripting additions

-- =====================================================
-- Drafts: Mail → Call Sheet (MacOS)
-- =====================================================
-- Notes for Drafts AppleScript actions (macOS):
--  • Drafts calls `on execute(d)` automatically. Do NOT call execute() at top level.
--  • Always return only primitive values (e.g., text) to avoid serialization issues.
--  • Avoid long UI interactions; Drafts may time out waiting on other apps.
--  • Uses NSURLConnection instead of curl to avoid sandbox DNS issues.
--  • Uses Gemini system_instruction for role/constraints (best practice for Gemini 3).
--  • Single API call combines reconstruction + extraction for lower latency.
-- =====================================================

-- *** USER SETTINGS ***
property geminiAPIKeyName : "Gemini_API_Key" -- Keychain service name for the Gemini API key
property geminiModel : "gemini-3.1-pro-preview" -- Primary model
property draftsTags : {"callsheet"}
property maxMessagesPerThread : 50 -- Cap to limit token/latency
property showAlerts : true -- Set false to suppress display alerts when running from Drafts
property requestTimeoutSecs : 180 -- Max seconds per Gemini API call

-- System instruction: defines the model's role and output constraints.
-- Placed in system_instruction (not user content) per Gemini 3 best practices.
property systemInstruction : "You are a production assistant for photographer David Degner. You process raw email threads into structured call sheets.

<rules>
- Extract ONLY facts explicitly stated in the email thread. Never infer or fabricate details.
- Omit conversational pleasantries, sign-offs, and email signatures.
- Use markdown formatting only. Do not use HTML.
- Do not wrap your output in code fences (no ```markdown or ``` delimiters).
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
</output_format>"

-- User prompt template: context-first, task-last (per Gemini best practices for long context)
property userPromptIntro : "Process the following raw email thread into a call sheet and reconstructed thread per your instructions.

<email_thread>"

property userPromptOutro : "</email_thread>

Produce the call sheet followed by the separator line and reconstructed thread now."

-- =============================
-- Utility helpers
-- =============================

on urlEncode(theText)
	set nsText to current application's NSString's stringWithString:theText
	-- Allow only unreserved URI characters; encode everything else
	set allowedChars to current application's NSCharacterSet's characterSetWithCharactersInString:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
	set encoded to nsText's stringByAddingPercentEncodingWithAllowedCharacters:allowedChars
	return encoded as text
end urlEncode

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

on lowerText(someText)
	set nsText to current application's NSString's stringWithString:(someText as text)
	return (nsText's lowercaseString()) as text
end lowerText

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

on normalizeSubject(s)
	set t to my trim(s as text)

	-- Strip leading bracket tags like [EXTERNAL], [EXT], [SECURE], etc. (repeatable)
	repeat while (t begins with "[")
		set closePos to offset of "]" in t
		if closePos > 0 then
			try
				set t to my trim(text (closePos + 1) thru -1 of t)
			on error
				exit repeat
			end try
		else
			exit repeat
		end if
	end repeat

	-- Strip repeated prefixes (case-insensitive), allowing optional space after colon
	repeat
		set lc to my lowerText(t)
		if lc begins with "re:" then
			set t to my trim(text 4 thru -1 of t)
		else if lc begins with "fw:" then
			set t to my trim(text 4 thru -1 of t)
		else if lc begins with "fwd:" then
			set t to my trim(text 5 thru -1 of t)
		else
			exit repeat
		end if
	end repeat

	return my trim(t)
end normalizeSubject

on createMessageLink(theMessage)
	tell application "Mail"
		set messageId to message id of theMessage
		set messageSubject to subject of theMessage
	end tell
	set messageLink to "message://%3c" & messageId & "%3e"
	set markdownLink to "[" & messageSubject & "](" & messageLink & ")"
	return markdownLink
end createMessageLink

on getAPIKeyFromKeychain(keyName)
	try
		set apiKey to do shell script "security find-generic-password -w -s " & quoted form of keyName
		return apiKey
	on error
		return missing value
	end try
end getAPIKeyFromKeychain

on sortMessagesByDate(messageList)
	set sortedMessages to messageList
	set messageCount to count of sortedMessages
	tell application "Mail"
		repeat with i from 1 to (messageCount - 1)
			repeat with j from (i + 1) to messageCount
				set messageI to item i of sortedMessages
				set messageJ to item j of sortedMessages
				set dateI to date received of messageI
				set dateJ to date received of messageJ
				if dateI > dateJ then
					set item i of sortedMessages to messageJ
					set item j of sortedMessages to messageI
				end if
			end repeat
		end repeat
	end tell
	return sortedMessages
end sortMessagesByDate

on dedupeByMessageID(messageList)
	set resultList to {}
	set seenIDs to {}
	tell application "Mail"
		repeat with m in messageList
			set mid to message id of m
			if seenIDs does not contain mid then
				set end of seenIDs to mid
				set end of resultList to m
			end if
		end repeat
	end tell
	return resultList
end dedupeByMessageID

-- =============================
-- Gemini call via NSURLConnection (sandbox-safe, no curl dependency)
-- =============================

on callGeminiAPI(apiKey, sysInstruction, promptText, modelName)
	-- Build request JSON with Cocoa (safe escaping)
	set dict to current application's NSMutableDictionary's dictionary()

	-- System instruction (Gemini 3 best practice: separate from user content)
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

	-- Generation config: temperature 1.0 is strongly recommended for Gemini 3
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

	-- Synchronous send via NSURLConnection (uses macOS native networking, sandbox-safe)
	-- sendSynchronousRequest returns {NSData, NSURLResponse, NSError} in AppleScript-ObjC
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
		set threadContent to ""
		set allRelated to {}
		set sel to {}

		with timeout of 600 seconds
			tell application "Mail"
				if not (exists message viewer 1) then
					my showAlert("No message viewer", "Open Mail and select one or more messages.")
					return ""
				end if
				set sel to (selected messages of message viewer 1)
				if sel is {} then
					my showAlert("No email selected", "Please select an email (or multiple emails) in the viewer.")
					return ""
				end if

				-- Collect related messages for each selection (subject-normalized), then dedupe by Message-ID
				repeat with baseMsg in sel
					set subjRaw to subject of baseMsg
					set subjCore to my normalizeSubject(subjRaw)
					set matches to (messages of message viewer 1 whose subject contains subjCore)
					repeat with m in matches
						set end of allRelated to m
					end repeat
				end repeat
			end tell
		end timeout

		set allRelated to my dedupeByMessageID(allRelated)
		set allRelated to my sortMessagesByDate(allRelated)

		-- Cap to the most recent N to keep prompts manageable
		set totalCount to (count of allRelated)
		if totalCount > maxMessagesPerThread then
			set startIndex to (totalCount - maxMessagesPerThread + 1)
			set allRelated to items startIndex thru totalCount of allRelated
		end if

		-- Build plain text thread content for the LLM (chronological)
		tell application "Mail"
			repeat with eachMessage in allRelated
				set emailSender to sender of eachMessage
				set emailSubject to subject of eachMessage
				set emailDate to date received of eachMessage
				set emailBody to content of eachMessage
				set ds to (date string of emailDate)
				set ts to (time string of emailDate)
				set messageLink to my createMessageLink(eachMessage)
				set threadContent to threadContent & "From: " & emailSender & " / Subject: " & emailSubject & " / Date: " & ds & " " & ts & linefeed & emailBody & linefeed & linefeed & "Message Link: " & messageLink & linefeed & "---" & linefeed & linefeed
			end repeat
		end tell

		-- Validate we actually got email content
		if (my trim(threadContent)) is "" then
			my showAlert("Empty Thread", "No email content could be extracted from the selected messages.")
			return ""
		end if

		-- Build the user prompt: context first, instruction last
		set fullPrompt to userPromptIntro & linefeed & threadContent & linefeed & userPromptOutro

		set geminiAPIKey to my getAPIKeyFromKeychain(geminiAPIKeyName)
		if geminiAPIKey is missing value then
			my showAlert("API Key Not Found", "Store your Gemini API Key in Keychain with the service name '" & geminiAPIKeyName & "'.")
			return ""
		end if

		-- Single API call: system instruction handles role/format, user content has the thread
		set apiResult to my callGeminiAPI(geminiAPIKey, systemInstruction, fullPrompt, geminiModel)
		if success of apiResult is false then return ""
		set rawOutput to body of apiResult

		-- Strip code fences if the model wrapped its output
		set cleanOutput to my stripCodeFences(rawOutput)

		-- Normalize line endings
		set fullContent to my replace_chars(cleanOutput, return, linefeed)

		-- Create the Draft via URL scheme (reliable across Drafts versions)
		set encodedContent to my urlEncode(fullContent)
		set draftURL to "drafts://x-callback-url/create?text=" & encodedContent
		repeat with t in draftsTags
			set draftURL to draftURL & "&tag=" & my urlEncode(t)
		end repeat
		open location draftURL
		return ""

	on error errMsg number errNum
		my showAlert("Error", ("An error occurred: " & errMsg & " (" & errNum & ")"))
		return ""
	end try
end execute
