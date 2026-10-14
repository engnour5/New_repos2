# NFC Card Tester (Flutter): iPhone and Android

A Windows app that talks to your contactless card the way a phone app does. It follows Apple's Core NFC rules
(iPhone) or Android's IsoDep rules, so you can see if the card works with phones without a Mac, a phone app or a
developer account.

## Folders

- `src_file`: all the source files: `lib` (the code), `test`, `windows` (the Windows runner), `pubspec.yaml`, `build.bat` and this README.
- `App_file`: the ready-to-run app. Keep `iphone_nfc_tester.exe` together with its DLLs and the `data` folder.

## Run it

1. Put the card on the Identive contactless reader. If PyApduTool is open, click **Disconnect** there.
2. Start `App_file\iphone_nfc_tester.exe`.
3. Choose **iPhone** or **Android** at the top right.
4. Click **Connect**. It is the first button of the bar at the top; the reader is picked by itself.
   "Simulated card" works without a reader: it runs your applet's logic.
5. Run a page. Click **Disconnect** when you are done, so other programs can use the reader.

**The AID box at the top right says which applet every screen talks to**: the first AID in it. The check, the APDU
console's "SELECT applet", Read card and the card unit test all use it, and the SELECT carries a length byte that
matches the AID rather than a fixed `0A`. On an iPhone the whole list is what an app would put in its Info.plist,
tried in order. **Burning an applet puts its AID in that box by itself**, so after loading a CAP with a different
instance AID the rest of the app follows the card instead of hunting for the applet that used to be there.

**iPhone and Android each keep their own results.** After a switch at the top right, every page (check, console,
Read card, full test, the phone picture) shows the results of the chosen phone, or nothing yet; switch back to see
the other phone's results again. The HTML report and the CSV use the results of the chosen phone. The log is shared.

The `App_file` folder (or `iPhone_NFC_Tester_win64.zip`) runs on any Windows 10/11 x64 PC.
Copy the whole folder, not only the exe.

**Where the files go.** Every report, dump, log and backup is written to **`Outputs_Files`**, the folder next to
`App_file` and `src_file`. The app works that out from where it runs rather than from a written-down path, so the
whole tool folder can be moved or checked out anywhere and the files follow it:

- the built app runs from `SmartCrad_NFC_APP\App_file`, so its parent is `SmartCrad_NFC_APP`;
- `flutter run` and the tests run from `SmartCrad_NFC_APP\src_file`, whose parent is the same folder.

A folder that is already there is always used. A new one is only made where the tool folder really is (a folder
holding `App_file` or `src_file`), so a test runner or a copy unpacked into a temporary folder never leaves an
`Outputs_Files` behind. If the app sits somewhere it may not write, it falls back to `Documents\iPhone NFC Tester`
rather than losing the file; the message after every save names the full path.

## Pages

| Page | What it does |
|---|---|
| **Home** | The first screen and the way you get around: one illustrated tile per feature, and **pressing a tile opens it**. There is no side column; **Home** at the top left comes back here from anywhere. The two phone tiles also set the phone rules, so "Android check" opens the check already on Android. The long guide is **not** on this screen: **Full guide** writes `guide.html` and opens it, and `App_file\Guide.html` ships with the app so it can be read without starting it. |
| iPhone / Android check | One click, read-only. Answers: will a phone app find this card and use the applet? |
| APDU console | One box: type one APDU in hex and press **Send** or Enter. Under the box you see what the command is (CLA, INS, P1, P2, offset, Lc, Le). Up/Down bring back earlier commands. The quick-command buttons fill the box: the plain ones are reads, and the amber ones under "these change the card" are UPDATE BINARY writes. A button only fills the box, so you can edit the bytes before pressing Send. |
| Read card | Reads the whole card, read-only. **OK only at exactly 32768 bytes** (32 KB, 0000-7FFF); fewer or more bytes give an **exception**. Every time it writes an HTML data report and opens it. |
| Card Unit Test | The card_test.ps1 checks, extra checks and the card size, always all 47 rows. Writes test bytes, then writes the saved bytes back. |
| **Run all tests** | One button: the check, the card read and the card unit test as an iPhone **and** as an Android, then the production checks, then one `card_readiness_*.html` report with a READY / NOT READY verdict. |
| Burner | The card manager side: load a CAP file, and read, select or delete the packages and applets on the card. |
| Log | Every APDU with its time. Search, filter, and save as a text file. |
| **Live log** (not a page) | A strip along the bottom of **every** page showing what was sent and what the card answered as it happens, so a test can be watched without leaving its screen. It opens by itself while a run is going and closes afterwards; press it to pin it open. Closed, it still shows the last line. `>>` is sent, `<<` is the answer (green at 90 00, red otherwise), and the name in brackets is the check that sent it. |
| Rules | The iPhone and Android rules the app applies, with their sources. |
| Error map | The applet's error map: every status word, the check that sends it (with its src line), what the meter should do, and the ORIGINAL applet's answer (with its F-number). The arrow next to an example puts it in the APDU console. |

## Error types (from the error map)

The tool gives every answer of the card a type, using the error map (`review\error_map.html`):

| Type | Meaning |
|---|---|
| `OK` | the answer the applet gives when the command is right |
| `READ 2`, `SELECT 4` ... | an error the applet sends on purpose: check 2 of READ BINARY, check 4 of SELECT ... The text says why, the src line, and what the meter should do (for example 69 86: send `00 A4 00 00 02 30 40`, then repeat the command). |
| `OLD F8`, `OLD F5` ... | not what the applet answers now, but what the ORIGINAL applet (the old .cap) answers, with the code review finding |
| `DATA` | the status word is right but the data is not |
| `UNEXPECTED` | neither the applet nor the original applet answers this (6F 00 = report it as a bug) |

You see it in the APDU console (under each answer), in the log, in the full test (TYPE column, and the "OLD APPLET
ANSWERS" count), in the HTML report (Type column with the explanation) and in the CSV.

**HTML report** (on the check page and the test page) saves everything that was run, the card and the setup in
`Outputs_Files\card_report_*.html`, and opens it in the browser.

**Every page the app writes is dark**, whatever the browser is set to: the report, the data report and the guide all
share one palette in `lib/core/html_theme.dart`. Printing is the exception. A browser usually leaves background
colours out of a printout, which would put pale text on white paper, so the print rules swap in a light palette and
the page stays readable on paper.

## Read card

It reads as much of the card as it can, shows the reading, and only then gives the result:

1. SELECT the applet by AID, GET UID, SELECT EF 3040. If one of them fails it is a **warning** and the reading goes on:
   the card's default applet may still answer (for example the old .cap answers 6D 00 to the SELECT by AID).
2. READ BINARY of **every** 256-byte block from 0000 to 7FFF. A block that fails is marked with its status word and the
   next block is read. A 6C xx answer is read again with Le = xx. A block that fails with an unexpected answer (6F 00,
   67 00...) is read again 16 bytes at a time, to save what can be read.
3. If the card stops answering, it is tapped again (up to 3 times); if it cannot be found again, everything read so far
   is kept.
4. After 32768 bytes, READ 7FFF with Le 02 shows whether the card has data past 7FFF.

- All 32768 bytes, nothing past 7FFF: **OK** (green), or **OK with warnings** (amber) when a step above failed.
- Fewer bytes (for example 32512 when the last block fails) or more bytes: **EXCEPTION**. The page first shows the data
  that was read (bytes not read show as `--` in red), then a message lists the parts not read and why.
- On an **iPhone** the card must answer 90 00 to an AID of the app's list first; if it does not (the old .cap answers
  6D 00), an iPhone never finds the card: EXCEPTION, nothing read.
- In every case: `Outputs_Files\card_data_*.html`, with the result, the parts not read and the warnings,
  the time, the CRC-32, a map of the 128 blocks (data, all 00, all FF, partly read, not read; click a block to jump to
  it), and every block as offset, hex and ASCII. **Save .bin** saves a 32768-byte file (bytes not read are 00).

## The card unit test

- **Tap 1:** C01-C31 (the strict-SELECT edge cases C16-C22/C24-C26/C28 were removed for the lenient applet), then the extra checks X02-X12, then the saved bytes are written back (C37-C40, X13-X14).
- **Tap 2 (power off and on):** C32-C36 and X15.
- Saved and written back: 0000-003F, 0100-01FE and 7FC0-7FFF.
- **Every check runs, even after a failure**, so a card that answers wrongly shows all its answers. For example the old
  .cap answers 6D 00 to the SELECT by AID (C01), but the test goes on and shows its answer to every check. The summary
  says when the answers match the ORIGINAL applet (80 A4 returns the card ID instead of 6E 00).
- A check that cannot reach the card is a FAIL that says why in the GOT column: "not sent: ..." (the phone did not
  find the card, the card was taken away, the iPhone's 60 s were over) or "not run: ..." (see below).
- If the three areas cannot be saved first, no command that writes is sent ("not run: could not save ..."); the
  read-only checks still run.
- If the card or the reader fails on the way, the remaining checks are listed as not sent, the saved bytes are still
  written back (straight through the reader if needed, or listed in the log to send by hand), tap 2 is still tried,
  and the error is shown at the end.
- On an **iPhone** the old .cap is never found (iOS's own SELECT of the AID gets 6D 00), so every row is "not sent".
  Choose **Android** to see the card's answer to every check.
- The TYPE column gives each answer its error-map type. With the old .cap, 24 of the 25 answers that do not pass are
  the ORIGINAL applet's answers (F1, F5, F6, F8) and the last one is C15 (DATA: 0020 holds the CA FE that C14 wrote).

| Extra check | What it checks |
|---|---|
| X01 | SELECT with P1 = 01 answers 6A 86 |
| X02 | SELECT EF 3040 with P1 = 02 answers 90 00 |
| X03 | UPDATE with a wrong CLA answers 6E 00 |
| X04, X05 | after SELECT MF 3F00, UPDATE answers 69 86 and writes nothing |
| X06-X08 | UPDATE of 255 bytes at 0100 (the largest short command) and reading them back |
| X09 | READ of 255 bytes ending exactly on 7FFF |
| X10 | GET UID with Le 00 (note only) |
| X11 | GET RESPONSE (00 C0) is not supported: 6D 00 (note only) |
| X12 | **Card size**: reads 256 bytes at a time from 0000 until the card stops (a 6C xx answer is read again with Le = xx). **Only 32768 bytes passes**; 32512 or any other size fails and shows the size found. |
| X13, X14 | writing back 0100-01FE and checking it |
| X15 | the card ID (GET UID) is the same after a new tap |

On an iPhone, C30 (SELECT of an AID that is not in the app's list) is **blocked by iOS**; that is expected.
On Android it reaches the card and answers 6A 86.

## Run all tests

Seven stages, in this order, so a card that is already wrong is found before anything is written to it:

1. iPhone check, 2. iPhone read card, 3. iPhone card unit test,
4. Android check, 5. Android read card, 6. Android card unit test, 7. the production checks.

The production checks are the ones no single screen makes, and they go straight to the reader:

| Check | Why it matters |
|---|---|
| The card selects the applet by itself | After a power-up, GET UID must answer without any SELECT. Without the "default selected" privilege an app has to know the AID to reach the card at all. |
| The card ID is usable | 10 bytes, and not the same byte repeated. |
| The card ID stays the same | Read after five power-ups. A back end that stores the card ID has to recognise the card again. |
| The card answers every tap | Five power-ups in a row. |
| An app can select the applet by its AID | SELECT of the AID in the box must answer 90 00, whether or not it is the default applet. |
| The data file EF 3040 is there | The first 16 bytes and the last byte (7FFF) both read, so the whole file is addressable. |
| The AID is in a registered category | A, D or F. Anything else is a warning only a real iPhone can settle. |

The verdict is **NOT READY** if anything failed, **READY, with warnings** if only warnings, **READY** if nothing at all.
Running it on the **simulated card** says so in big letters next to the verdict, because a READY from the simulator
says nothing about real hardware.

`--run-all` does the same from the command line.

## The burner (card manager)

This page does what PyApduTool's Manager, Package and Applet windows do: it talks to the card's **Issuer Security
Domain** over a GlobalPlatform **SCP02** secure channel. No phone can send these commands, so the iPhone and Android
rules do not apply here; everything goes straight to the reader.

1. **Keys.** Three boxes, one for each key: **Key-ENC** (auth), **Key-MAC** and **Key-DEK**. Each is 16 bytes of hex,
   and the box counts the bytes and ticks when it has 16. That is the whole setup: **nothing else about the card
   manager comes from a file.** The keys are hidden behind `*` until the eye is clicked.
   - **Save keys** keeps them in `%APPDATA%\NFC Card Tester\gp_keys.ini`, and the tool reads that file when it starts,
     so they only have to be typed once.
   - **From a config.ini** takes the three keys out of a PyApduTool `config.ini` (`[ControlCenter]` with `authkey`,
     `cmackey` and `dekkey`). Only those three values are read; the readers, history and CAP list in that file are
     PyApduTool's own and are ignored.
   - **Default test key** fills in the test card's own keys from PyApduTool's `config.ini` (`[ControlCenter]`). It
     looks in `Tools\PyApduTool_Release` next to the app first, so it works wherever the SVN tree is checked out, then
     at the old places on this PC. The simulated card holds the same keys, so this one key set opens the simulator and
     the real card. With no `config.ini` it is the factory key `40 41 ... 4F`.
   - **Key ver.** is the key version to authenticate with; "any" (0) lets the card pick, which is what the test card
     needs (it answers with key version 1).
2. **Open channel.** INITIALIZE UPDATE, then EXTERNAL AUTHENTICATE. The card reports its key version, the protocol and
   its sequence counter.
3. **On the card.** GET STATUS lists the packages (with the applets each one defines), the installed applets with
   their life cycle and privileges, and the card manager itself.
   - The arrow button next to an applet SELECTs it, the way a phone app would.
   - The bin button deletes a package or an applet, after a confirmation that says what goes with it.
4. **Burn a CAP file.** Choose the `.cap` your build makes. The page shows the package AID, the applets in it, the
   version and how many blocks it takes **before anything is sent**. Then INSTALL [for load], the LOAD blocks, and
   INSTALL [for install and make selectable].
   - **Default selected** gives the applet privilege `04`, so the card picks it after every power-up. Your test card
     needs this.
   - **Delete the package first** is on by default, because a card refuses a package whose AID it already has.
   - **Only one applet on a card can be "Default selected".** If another applet already holds it, the card refuses the
     install with `69 85`, so the app checks first and names the applet that has it before sending anything. Delete
     that applet (its package can stay) or untick the box.
   - **What the card would refuse is caught before anything is sent**, because a refusal halfway leaves the card
     worse off (the old package deleted, or the new one loaded with no applet): the package already there with
     "Delete the package first" off, an instance AID another applet already has, and "Default selected" held by an
     applet of another package. The refusal comes before the confirmation.
     - GET STATUS does not say which package an applet came from. So when the applet in the way has an AID no package
       defines, only the delete can tell, and the message then says that the old package was deleted and nothing new
       was loaded.
   - A path pasted in quotes, as Explorer's "Copy as path" gives it, is fine.

**About the keys and the card's try counter:**

- The keys never travel to the card: only cryptograms do. They are never written to a report, a log or the APDU list,
  and the boxes stay masked until you ask to see them.
- The tool checks the **card's own cryptogram before sending EXTERNAL AUTHENTICATE**. So a wrong key set stops with
  "the card did not prove it has the same keys" and the card never records a failed authentication.
- A card-manager channel lives only while the card stays powered and the card manager stays selected. Running a check,
  a read or the full test taps the card, which resets it, so the channel closes and the page says so. Open it again
  before using the burner.
- After a delete or a load the card holds different code, so the earlier check, read and test results are cleared.

**Verified on the real test card (2 Oct 2026):** the channel opened on the first try (SCP02, key version 1), the EMG
package was deleted, the CAP was loaded in 4 blocks and installed as the default applet, and the card unit test then
passed 40/40 and 15/15 on it. A fresh install gives a new card ID and a 32 KB file of `00`.

**On the simulated card** the burner works like on the test card, so a burn can be tried out with no reader:

- Its card manager holds the **default test key**, the keys of PyApduTool's `config.ini`, as the test card does, under
  **key version 1**. So "any" and "1" both open it, whether the keys come from "Default test key" or "From a
  config.ini". Any other key set is refused as a card would refuse it, and the error says to click "Default test key".
- **Every install is a new applet instance:** a new random card ID and a file of `00`, because the applet's
  `install()` makes them anew (they are static fields, which belong to the package). An applet of another package
  keeps memory of its own.
- With **no default applet**, the card manager answers after a power-up, as GlobalPlatform has it: SELECT of an AID
  that is not there answers `6A 82`, other commands `6D 00`, and card-manager commands without the secure channel
  `69 82`.
- It checks what a card checks: the LOAD blocks come in order, the `C4` length matches what came, and the package is
  the one INSTALL [for load] announced. GET STATUS answers that do not fit end in `63 10`, and the rest follows on "get
  next". A wrong C-MAC ends the channel.

`tool\` holds scripts that run against the **real** reader. They are kept out of `test\` on purpose, so a plain
`flutter test` can never change the card. Run one with `flutter test tool\<name>.dart`.

| Script | What it does |
|---|---|
| `real_card_list.dart` | **Read-only.** Lists everything on the card with its privileges, and shows what the card picks after a power-up. |
| `real_card_burn.dart` | Deletes the EMG package and loads it back, to prove DELETE, INSTALL and LOAD on a real card. |
| `real_card_install_emg.dart` | Installs the EMG applet from the built CAP. `asDefaultApplet` at the top chooses the privilege. |
| `real_card_emg_default.dart` | Makes EMG the default selected applet, taking the privilege off whichever applet holds it. |
| `real_card_default_selected.dart` | Installs both ways and probes the card after each, to show what the privilege actually changes. |
| `write_guide_html.dart` | Regenerates `App_file\Guide.html` from the guide text. |
| `write_sample_html.dart` | Writes one of each page the app generates, from the simulated card, to check how they look. Needs no reader. |

## The phone rules

**iPhone (Core NFC):**
- A tap: the field goes off and on, then iOS sends SELECT by AID for each AID of the app's Info.plist list, in order.
  The first AID that answers 90 00 lets the app have the card.
- The app can only SELECT by AID the AIDs of its list. Payment AIDs are always blocked.
- iOS rebuilds each APDU from its fields; no automatic GET RESPONSE or 6C xx retry.
- A reader session ends after 60 seconds. NFC needs a paid Apple Developer account.

**Android (IsoDep):**
- Any ISO-DEP card is found without an AID. By default Android first checks for NDEF data
  (SELECT D2 76 00 00 85 01 01); reader-mode apps can skip it.
- IsoDep.transceive() sends the bytes exactly as given; nothing is blocked.
- No session limit; each command has a timeout. Many phones send at most 261 bytes per command.
- Any app with the NFC permission works; no developer account is needed.

A PC reader is not a phone: the antenna, the NFC chip timing and OS bugs cannot be tested here.
A real phone app is still the final proof.

## Build and test

- `src_file\build.bat` builds the app and refreshes `App_file` (Flutter 3.47.6 in `D:\Tools\flutter`, portable Git in `D:\Tools\MinGit`).
- Tests: `flutter test` with `D:\Tools\flutter\bin` on the PATH.
  - `test\core_test.dart`: APDU parsing, the iPhone and Android rules, the phone check, the card unit test
    (both phones, card size, data written back byte for byte; the old .cap, ported from the original Java code, on
    Android and iPhone; areas that cannot be saved; a failed command; the card taken away), Read card (32 KB OK, a
    32512-byte card, a card with data past 7FFF, a card without the applet), the error map (every example of the map,
    and the types of a whole full test on the applet and on the old .cap), the console's command breakdown, and both
    HTML reports.
  - `test\gp_test.dart`: the SCP02 session keys, cryptograms, C-MAC and chained ICV against numbers produced by a
    different implementation (Python with pycryptodome), so a mistake the tool and its own simulator would agree on is
    still caught; CAP file reading; and the burner authenticating, listing, deleting and loading on the simulated card,
    with the key version, a new card ID and file per install, a second package, no default applet, GET STATUS over
    several answers, LOAD blocks out of order or that do not add up, and a wrong C-MAC.
  - `test\burner_test.dart`: the burner page pressed through like a person would (test key, Open channel, a CAP path
    pasted in quotes, Load and install with its dialog, SELECT, delete the applet and the package, load again without
    "Default selected"), and every case the card would refuse caught before anything is sent.
  - `test\ui_test.dart`: every page before Connect, after Connect, after the iPhone and Android runs, in both themes
    and after Disconnect, at 1440 x 900 and 1100 x 700, failing on any layout error; and the burner's whole
    open-list-delete-load run through the screens.
- Command line: `--sim`, `--android`, `--connect`, `--run-check` | `--run-read` | `--run-test` | `--run-console` |
  `--run-all` | `--run-burner`, `--keys <config.ini>`, `--page 1..10` (after the run), `--report` (save the HTML
  report without opening it), `--light`.
  - `--run-burner` is read-only: it reads the key file, opens the secure channel and lists the card. There is no
    command-line flag that deletes or loads, on purpose.
- `build.bat` builds with `--no-tree-shake-icons`, so the full icon font is always included. A cut-down font from an
  older build once left new icons blank.

## Code

- `lib/core`: APDU parsing, status words, the error map (`error_map.dart`: the map and `explainAnswer`), the iOS
  rules, the phone session (iPhone and Android), the phone check, the card unit test, Read card and the HTML reports.
- `lib/gp`: the card manager side. `scp02.dart` (the secure channel: session keys, cryptograms, the C-MAC and its
  chained ICV), `cap_file.dart` (a small ZIP reader and the Java Card component load order), `gp_keys.dart` (reading
  the key file) and `card_manager.dart` (GET STATUS, DELETE, INSTALL and LOAD).
- `lib/card`: the PC/SC reader (winscard.dll through dart:ffi, in a worker isolate), the simulated card, and
  `simulated_isd.dart`, a simulated card manager that speaks SCP02 so the burner can be used without a reader.
- `lib/state/app_state.dart`: Connect/Disconnect, what the screens show, and the card work behind the buttons.
- `lib/ui`: the theme, the animated phone, the shared widgets and the seven pages.
