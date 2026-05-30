# claude-brain-sync — Neuinstallation auf Windows 10

Anleitung für eine **frische Installation** des Plugins (Fork mit Fork-Bomben-Fix)
auf einer Windows-10-VM, die noch Teil des bestehenden Brain-Netzwerks werden
soll (Daten-Repo: `omonien/my-claude-brain`).

Plugin-Quelle: `omonien/claude-brain` @ `main` (enthält die Patches
`--bare` + `--no-session-persistence` + Detail-Logs).

---

## 1. Voraussetzungen installieren

Öffne **PowerShell als Administrator** und installiere die Tools, falls noch
nicht vorhanden:

```powershell
# Paketmanager (winget kommt mit Windows 10/11 vorinstalliert)
winget install --id Git.Git              -e --source winget
winget install --id stedolan.jq          -e --source winget
winget install --id Microsoft.VisualStudioCode -e --source winget   # falls noch nicht da
```

Falls Claude Code noch nicht installiert ist, hole es von
<https://claude.com/claude-code> (oder VS-Code-Extension „Claude Code").

> **Wichtig:** Das Plugin nutzt Bash-Skripte. Die kommen mit Git for Windows
> als **Git Bash** mit. Du musst Git Bash nicht manuell starten — die
> SessionStart-Hooks rufen `bash` direkt auf, und das wird via `PATH`
> gefunden.

Verifikation in einer neuen PowerShell-Session:

```powershell
git --version
jq --version
bash --version
```

Alle drei müssen Versionen ausgeben (kein „nicht gefunden").

---

## 2. GitHub-Zugang für die VM

Du brauchst Read-Zugang zum **privaten** Daten-Repo `omonien/my-claude-brain`.
Einfachster Weg: GitHub CLI authentifizieren.

```powershell
winget install --id GitHub.cli -e --source winget
gh auth login
# Wähle: GitHub.com → HTTPS → Y (authenticate Git) → Login with web browser
```

`gh auth login` hinterlegt Credentials, die `git push`/`git pull`
gegen `omonien/my-claude-brain` ohne weitere Eingabe nutzen.

---

## 3. Claude Code starten und Plugin installieren

Starte VSCode, öffne ein beliebiges Projekt (oder einen leeren Ordner),
öffne die Claude-Code-Sidebar und gib in der Chat-Eingabe folgende
Slash-Commands **nacheinander** ein:

### 3a. Marketplace registrieren (zeigt auf den Fork mit den Patches)

```
/plugin marketplace add github:omonien/claude-brain
```

Erwartete Antwort: „Added marketplace: omonien/claude-brain".

> Hintergrund: Ein „Marketplace" bei Claude Code ist einfach ein Git-Repo
> mit `plugin.json` an der Wurzel. Indem wir den Fork als Marketplace
> registrieren, bekommt Claude Code beim Plugin-Install den gepatchten
> Code.

### 3b. Plugin installieren

```
/plugin install claude-brain-sync@omonien/claude-brain
```

Erwartete Antwort: bestätigt Installation, listet skills (brain-init,
brain-sync, brain-log, …) und aktiviert das Plugin.

### 3c. Brain dem bestehenden Netzwerk anschließen

Hier **nicht** `/brain-init` (das würde ein neues, leeres Brain anlegen),
sondern `/brain-join` — der zieht das vorhandene Brain vom Daten-Repo:

```
/brain-join https://github.com/omonien/my-claude-brain.git
```

Erwartete Schritte:
- Klont `omonien/my-claude-brain` nach `~/.claude/brain-repo`
- Registriert diese Maschine (neue `machine_id`) im Repo
- Merged das vorhandene Brain mit dem (leeren) Local-State der VM
- Aktiviert `auto_sync`

---

## 4. Verifikation: Sind die Patches im Cache aktiv?

Öffne **Git Bash** und führe das Verify-Script aus:

```bash
curl -fsSL https://raw.githubusercontent.com/omonien/claude-brain/main/scripts-local/verify-windows-install.sh -o ~/verify.sh
bash ~/verify.sh
```

Oder copy-paste das Inline-Script aus
`scripts-local/verify-windows-install.sh`.

Erwartete Ausgabe (gekürzt):
```
[ok] Marketplace HEAD: 66fb048 fix(sync): add --bare to stop ...
[ok] --bare gefunden in: merge-semantic.sh evolve.sh (Marketplace)
[ok] --bare gefunden in Cache: ~/.claude/plugins/cache/...
[ok] Daten-Remote in brain-config.json zeigt auf omonien/my-claude-brain
[ok] Alles in Ordnung.
```

Falls der Cache **nicht** gepatcht ist (kann passieren, wenn Claude Code
intern eine andere Version cacht), patcht das Script den Cache automatisch
aus dem Marketplace.

---

## 5. Smoke-Test

1. VSCode einmal komplett **neu starten**.
2. Beim Start läuft der `SessionStart`-Hook → `pull.sh` → ggf.
   `merge-semantic.sh` → `claude -p --bare --no-session-persistence`.
3. Im **Task-Manager** (Ctrl+Shift+Esc, Tab „Details") **darf kein**
   `claude.exe` im Sekundentakt neu starten. Falls doch → Patches nicht
   aktiv, siehe Schritt 4.
4. In der **Session-Auswahl** (oben in der Claude-Sidebar) **darf kein**
   neuer Eintrag „You are merging knowledge bases…" auftauchen.
5. Wenn ein Merge gelaufen ist, sollte unter `~/.claude/brain-runs/`
   eine `*-merge.log` liegen. Anschauen mit `/brain-log verbose`.

---

## 6. Troubleshooting

| Symptom | Ursache | Fix |
|---|---|---|
| `bash: jq: command not found` beim Hook | `jq` nicht in PATH | PowerShell neu starten nach winget-Install, oder `where jq` prüfen |
| `Permission denied (publickey)` beim brain-join | GitHub-Auth fehlt | `gh auth login` erneut ausführen |
| Sessions tauchen weiter auf | Cache nicht gepatcht | `bash ~/verify.sh` erneut laufen lassen |
| `/plugin install` schlägt fehl | falscher Marketplace-Name | `/plugin marketplace list` prüfen, neu `add` |
| Brain pull dauert > 30 s | Großes Daten-Repo | Einmal ist normal, danach inkrementell |

---

## Anhang: Was ist der Unterschied zum bestehenden Windows-VM-Workflow?

Auf der existierenden VM (`e6b4e3ac`) lief das Plugin schon, **mit Fork-Bug**.
Dort haben wir mit `apply-patches-on-other-machine.sh` nachträglich die
Cache-Files überschrieben.

Auf der neuen Windows-10-VM installieren wir **frisch aus dem Fork** — der
Marketplace und Cache enthalten von Anfang an die Patches. Trotzdem führen wir
in Schritt 4 ein Verify aus: Claude Code könnte intern bei `/plugin install`
einen Snapshot anlegen, der vom Marketplace-Stand abweicht. Defense in depth.
