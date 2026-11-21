# Build Notes: Problems Hit and Why the Fixes Worked

Each entry: what we saw, what was actually wrong, the fix, and why it worked. The environment was Windows Server 2016, Windows PowerShell 5.1, a multi-domain AD forest, and the tool compiled to an EXE with PS2EXE.

---

## 1. ps2exe would not install on the server

**Symptom:** `Invoke-PS2EXE` not recognized; `Install-Module ps2exe` returned `NoMatchFoundForCriteria`.

**Cause:** The management server cannot reach the PowerShell Gallery.

**Fix:** Compile on a workstation, copy the EXE over.

**Why it worked:** ps2exe is only a build tool. The compiled EXE does not depend on it.

## 2. "Run with PowerShell" opened and closed instantly

**Symptom:** A flash of red text, then nothing to read.

**Cause:** A parse error stops the script before any line runs, so logging inside the script never starts.

**Fix:** Launch from an open console with `powershell.exe -NoExit -ExecutionPolicy Bypass -File <script>`.

**Why it worked:** `-NoExit` keeps the host open after the script dies. In-script logging cannot catch errors that happen before the script starts.

## 3. Emoji broke the parser

**Symptom:** Dozens of `Unexpected token` errors containing junk characters.

**Cause:** PowerShell 5.1 reads a UTF-8 file without a BOM as the system ANSI code page. Each emoji is several bytes, which become several junk characters, some of them quotes, which breaks string boundaries.

**Fix:** ASCII only in the source: status tags like `[OK]` and `[FAIL]`, hyphens instead of dashes and box-drawing lines.

**Why it worked:** ASCII reads the same under every encoding. The HTML log still shows symbols because those are HTML entities rendered by the browser.

## 4. `PlaceholderText` not found

**Cause:** `TextBox.PlaceholderText` exists only in .NET Core WinForms, not the .NET Framework WinForms that PowerShell 5.1 uses.

**Fix:** Removed it. The error's `line:char` pointed straight at it.

## 5. Cross-domain adds failed with referrals

**Symptom:** `A referral was returned from the server` when the user and the group were in different child domains.

**Cause:** `Add-ADGroupMember -Server <group domain> -Members <DN string>` asks the group's DC to resolve a DN it does not own.

**Fix:** Fetch the target as a live `ADUser` object from its own domain, then pass the object.

**Why it worked:** The cmdlet references the member from the object it already holds instead of searching for a foreign DN. Global groups still cannot take members from other domains, by AD design, and those correctly report `[FAIL]`.

## 6. Graph sign-in: "The underlying connection was closed"

**Cause:** On Server 2016, `Invoke-RestMethod` in PowerShell 5.1 does not use TLS 1.2 by default, and Microsoft sign-in endpoints require it. Tools built on the Microsoft.Graph module work because the module sets TLS 1.2 itself.

**Fix:** `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12` before any REST call.

## 7. The script showed as one long line in Notepad

**Cause:** Unix `LF` line endings. Notepad on Server 2016 only understands `CRLF`.

**Fix:** Convert to `CRLF`. The code always ran; it only displayed wrong.

## 8. EXE: "Cannot bind argument to parameter 'Path' because it is null"

**Cause:** `$PSScriptRoot` is empty inside a PS2EXE binary.

**Fix:** Fall back to `$MyInvocation.MyCommand.Path`, then to the running process path.

## 9. Cloud groups missing from the confirmation window

**Cause:** A bare username was typed. AD resolves it; Graph needs a full UPN and returned 404, and the preview's `catch` returned an empty list silently.

**Fix:** Every cloud preview failure now logs a `[WARN]` line, and the tool refuses to run cloud copy without `@domain` in both fields. Appending a default domain was tried and rejected: guessing could target the wrong account.

**Lesson:** Never return an empty result from a `catch` without saying why.

## 10. Status checks have to run before the approval filter

**Cause:** The "operator unchecked this" filter ran before the status checks. Dynamic, synced and already-member groups are never checkable, so they were silently skipped instead of reported.

**Fix:** Order is now: blocked, licensing, dynamic, synced, already a member (each reported), then the approval filter, then the add.

## 11. `BeginInvoke` overload error

**Cause:** `$form.BeginInvoke($scriptblock)` needs a .NET delegate; a scriptblock is not converted.

**Fix:** Update the selection count directly from events that fire after the change.

## 12. A checkbox kept getting clipped

**What did not work:** `AutoSize`, explicit sizes, flat styles.

**Cause:** Position. The control extended past the edge of the panel that contained it.

**Fix:** Move it out of the panel onto the form.

**Lesson:** When property changes do not change a rendering bug, check the geometry.

## 13. Block list missed suffixed group names

**Cause:** Some group names carry a generated suffix (for example `Restricted - Sample Group A_0a1b2c3d4e5f`), so exact matching missed them. The list was also only checked on the cloud side.

**Fix:** `Test-DoNotMirror` matches exact name or prefix, everywhere.

**Tradeoff:** A prefix can over-match an unrelated group that starts with the same text.

## 14. Other admins could not decrypt the secret

**Cause:** DPAPI `CurrentUser` scope ties the blob to one Windows account. A stale EXE built from an old script later re-encrypted it to a different account.

**Fix:** `LocalMachine` scope, an automatic migration from user scope, and a folder ACL limiting who can read the config.

**Lesson:** Confirm the source contains the change before compiling. The error text from the old build gave it away.

## 15. A cascade of error dialogs after a successful run

**Cause:** A WinForms timer reset a button label after two seconds. In the compiled EXE its tick handler could not resolve the outer variables, threw, and never reached `Stop()`, so it fired forever.

**Fix:** No timers. The label resets on the next click, and the copy handler is wrapped in try/catch so one error produces one dialog.

## 16. Bugs found by the test suite

Adding PSScriptAnalyzer and Pester with mocked AD and Graph found two bugs that manual runs had not:

- **Deselect All still added everything.** The approval check was written `$array -ne $null`. In PowerShell that filters the array instead of testing it, so an empty approved list read as "no filter." Partial selections worked, which is why manual testing never hit it. Fixed with `$null -ne $array`, covered by a regression test for both on-prem and cloud.
- **A rename collided with an existing variable.** Renaming `$matches` (an automatic variable, flagged by the analyzer) to `$found` collided with a `$found` already used in the same function, which would have broken every user lookup. The first Pester run failed on it before it shipped.

---

## Rules for PowerShell 5.1 tools on Server 2016

1. ASCII only in the source.
2. CRLF line endings.
3. TLS 1.2 before any raw REST call.
4. No `$PSScriptRoot`-only paths if it will be compiled.
5. No .NET Core-only WinForms properties.
6. No timers or `BeginInvoke` in compiled GUIs.
7. Wrap every click handler in try/catch.
8. Never return an empty result from a `catch` silently.
9. Status checks before filters.
10. Put `$null` on the left of comparisons.
11. DPAPI `LocalMachine` plus a folder ACL for shared tools.
12. Run PSScriptAnalyzer and Pester before every build.
