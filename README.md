# AD-Declutter - Disabilitazione automatica di utenti e computer AD inattivi oltre 60 giorni

Documento operativo per l’utilizzo di uno script PowerShell che identifica e disabilita oggetti Active Directory (utenti e PC) inattivi da oltre 60 giorni, con modalità di test e modalità reale.

## 1. Descrizione script PowerShell

- Lo script cerca account utente e computer abilitati che risultano inattivi da più di 60 giorni.

- Per stimare linattività usa il campo LastLogonDate; se non disponibile, usa whenCreated come fallback per gli oggetti mai utilizzati.

- Per motivi di sicurezza, esclude gli account critici di default: Administrator, Guest e krbtgt.

- Esclude anche gli account con adminCount=1, così da non disabilitare automaticamente account privilegiati o protetti.

- Per i computer, esclude i Domain Controller e i server, limitando l-azione ai PC/workstation.

- Genera tre file di log: elenco utenti candidati, elenco computer candidati e transcript delle azioni.

- Supporta una modalità DryRun (test) per verificare limpatto prima dellesecuzione reale.

- Facoltativamente può spostare gli oggetti disabilitati in OU dedicate di quarantena.

Nota importante: LastLogonDate/lastLogonTimestamp in Active Directory non è un indicatore in tempo reale. Prima di attivare la disabilitazione automatica in produzione è consigliata una fase di validazione in DryRun e un controllo delle eccezioni (account di servizio, account condivisi, postazioni speciali, dispositivi di reparto, ecc.).

## 2. Script PowerShell completo

Salvare il file con nome suggerito Disable-StaleADObjects.ps1 e verificarne prima l’esecuzione in ambiente di test o in modalità DryRun.

```
[CmdletBinding()]
param(
[int]$DaysInactive = 60,
[switch]$DryRun = $true,
# Facoltativo: limita la ricerca a OU specifiche
[string]$UsersSearchBase = "",
[string]$ComputersSearchBase = "",
# Facoltativo: OU di quarantena per gli account disabilitati
[string]$DisabledUsersOU = "",
[string]$DisabledComputersOU = "",
```


```
\# Percorso log
[string]$LogFolder = "C:\Logs\AD-StaleObjects"
)
Import-Module ActiveDirectory -ErrorAction Stop
# =========================
# Configurazione di sicurezza
# =========================
$ExcludedUsers = @(
"Administrator",
"Guest",
"krbtgt"
)
# Wildcard di esclusione per account tecnici / servizio
# Personalizzale in base al tuo ambiente
$ExcludedUserPatterns = @(
"svc_*",
"adm_*",
"sql_*",
"backup_*"
)
# Computer da escludere esplicitamente
$ExcludedComputers = @(
# es. "PC-CASSA01", "PC-LAB01"
)
# =========================
# Setup log
# =========================
if (-not (Test-Path $LogFolder)) {
New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}
$RunDate = Get-Date
$RunStamp = $RunDate.ToString("yyyyMMdd-HHmmss")
$Cutoff = $RunDate.AddDays(-$DaysInactive)
$UserCsv = Join-Path $LogFolder "StaleUsers-$RunStamp.csv"
$ComputerCsv = Join-Path $LogFolder "StaleComputers-$RunStamp.csv"
$ActionLog = Join-Path $LogFolder "Actions-$RunStamp.log"
Start-Transcript -Path $ActionLog -Append | Out-Null
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Disabilitazione oggetti AD inattivi" -ForegroundColor Cyan
Write-Host "Cutoff inattività: $Cutoff" -ForegroundColor Yellow
Write-Host "DryRun: $DryRun" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Cyan
function Test-ExcludedUser {
```


```
param([Microsoft.ActiveDirectory.Management.ADUser]\$User)
if ($ExcludedUsers -contains $User.SamAccountName) {
return $true
}
foreach ($pattern in $ExcludedUserPatterns) {
if ($User.SamAccountName -like $pattern) {
return $true
}
}
# Esclude account privilegiati/protetti
if ($User.adminCount -eq 1) {
return $true
}
return $false
}
function Get-EffectiveLastActivity {
param($Object)
# Se LastLogonDate è valorizzata, usala
if ($Object.LastLogonDate) {
return [datetime]$Object.LastLogonDate
}
# Se non ha mai loggato, usa la data di creazione come fallback
if ($Object.whenCreated) {
return [datetime]$Object.whenCreated
}
return $null
}
# =========================
# 1) UTENTI
# =========================
Write-Host "`n[1/2] Analisi utenti..." -ForegroundColor Green
$userProps = @(
"Enabled",
"LastLogonDate",
"whenCreated",
"adminCount",
"PasswordNeverExpires",
"DistinguishedName",
"Description"
)
$userParams = @{
Filter = 'Enabled -eq $true'
```


```
Properties = \$userProps
ErrorAction = 'Stop'
}
if ($UsersSearchBase -and $UsersSearchBase.Trim() -ne "") {
$userParams["SearchBase"] = $UsersSearchBase
}
$AllUsers = Get-ADUser @userParams
$StaleUsers = foreach ($u in $AllUsers) {
if (Test-ExcludedUser -User $u) {
continue
}
$lastActivity = Get-EffectiveLastActivity -Object $u
if (-not $lastActivity) {
continue
}
if ($lastActivity -lt $Cutoff) {
[PSCustomObject]@{
ObjectType = "User"
SamAccountName = $u.SamAccountName
Name = $u.Name
Enabled = $u.Enabled
LastActivity = $lastActivity
LastLogonDate = $u.LastLogonDate
WhenCreated = $u.whenCreated
DistinguishedName = $u.DistinguishedName
Description = $u.Description
AdminCount = $u.adminCount
PasswordNeverExpires = $u.PasswordNeverExpires
}
}
}
$StaleUsers = $StaleUsers | Sort-Object LastActivity
$StaleUsers | Export-Csv -Path $UserCsv -NoTypeInformation -Encoding UTF8
Write-Host "Utenti candidati: $($StaleUsers.Count)" -ForegroundColor Yellow
foreach ($u in $StaleUsers) {
Write-Host "Utente inattivo: $($u.SamAccountName) |
LastActivity=$($u.LastActivity)" -ForegroundColor DarkYellow
try {
if ($DryRun) {
Disable-ADAccount -Identity $u.SamAccountName -WhatIf
if ($DisabledUsersOU -and $DisabledUsersOU.Trim() -ne "") {
Write-Host "[DRYRUN] Move-ADObject '$($u.DistinguishedName)' ->
'$DisabledUsersOU'"
}
```


```
}
else {
Disable-ADAccount -Identity $u.SamAccountName -Confirm:$false
if ($DisabledUsersOU -and $DisabledUsersOU.Trim() -ne "") {
Move-ADObject -Identity $u.DistinguishedName -TargetPath
$DisabledUsersOU -Confirm:$false
}
Write-Host "Disabilitato utente: $($u.SamAccountName)" -ForegroundColor Red
}
}
catch {
Write-Warning "Errore su utente $($u.SamAccountName): $($_.Exception.Message)"
}
}
# =========================
# 2) COMPUTER (solo PC, non server/DC)
# =========================
Write-Host "`n[2/2] Analisi computer..." -ForegroundColor Green
$computerProps = @(
"Enabled",
"LastLogonDate",
"whenCreated",
"OperatingSystem",
"DistinguishedName",
"Description"
)
$computerParams = @{
Filter = 'Enabled -eq $true'
Properties = $computerProps
ErrorAction = 'Stop'
}
if ($ComputersSearchBase -and $ComputersSearchBase.Trim() -ne "") {
$computerParams["SearchBase"] = $ComputersSearchBase
}
$AllComputers = Get-ADComputer @computerParams
$StaleComputers = foreach ($c in $AllComputers) {
# Esclusione esplicita
if ($ExcludedComputers -contains $c.Name) {
continue
}
# Esclude Domain Controllers
if ($c.DistinguishedName -match "OU=Domain Controllers,") {
continue
```


```
}
# Esclude server: vogliamo "PC", non server
if ($c.OperatingSystem -match "Server") {
continue
}
$lastActivity = Get-EffectiveLastActivity -Object $c
if (-not $lastActivity) {
continue
}
if ($lastActivity -lt $Cutoff) {
[PSCustomObject]@{
ObjectType = "Computer"
SamAccountName = $c.SamAccountName
Name = $c.Name
Enabled = $c.Enabled
LastActivity = $lastActivity
LastLogonDate = $c.LastLogonDate
WhenCreated = $c.whenCreated
OperatingSystem = $c.OperatingSystem
DistinguishedName = $c.DistinguishedName
Description = $c.Description
}
}
}
$StaleComputers = $StaleComputers | Sort-Object LastActivity
$StaleComputers | Export-Csv -Path $ComputerCsv -NoTypeInformation -Encoding UTF8
Write-Host "Computer candidati: $($StaleComputers.Count)" -ForegroundColor Yellow
foreach ($c in $StaleComputers) {
Write-Host "Computer inattivo: $($c.Name) | LastActivity=$($c.LastActivity)" -
ForegroundColor DarkYellow
try {
if ($DryRun) {
Disable-ADAccount -Identity $c.SamAccountName -WhatIf
if ($DisabledComputersOU -and $DisabledComputersOU.Trim() -ne "") {
Write-Host "[DRYRUN] Move-ADObject '$($c.DistinguishedName)' ->
'$DisabledComputersOU'"
}
}
else {
Disable-ADAccount -Identity $c.SamAccountName -Confirm:$false
if ($DisabledComputersOU -and $DisabledComputersOU.Trim() -ne "") {
Move-ADObject -Identity $c.DistinguishedName -TargetPath
$DisabledComputersOU -Confirm:$false
}
```


```
Write-Host "Disabilitato computer: \$(\$c.Name)" -ForegroundColor Red
}
}
catch {
Write-Warning "Errore su computer $($c.Name): $($_.Exception.Message)"
}
}
Write-Host "`nReport generati:"
Write-Host " - $UserCsv"
Write-Host " - $ComputerCsv"
Write-Host " - $ActionLog"
Stop-Transcript | Out-Null
```

## 3. Come usarlo

## 3.1 Prima esecuzione in test

La prima esecuzione deve essere sempre effettuata in modalità di test, così da verificare quali oggetti verrebbero coinvolti senza apportare modifiche reali in Active Directory.

## Comando di esempio:

.\Disable-StaleADObjects.ps1 -DaysInactive 60 -DryRun

- Non disabilita alcun oggetto AD.

- Mostra a video gli account candidati alla disabilitazione.

- Genera i file CSV e il log delle azioni previste.

- Permette di verificare esclusioni, OU coinvolte e correttezza del criterio di inattività.

## 3.2 Esecuzione reale

Dopo aver validato l’elenco prodotto dalla modalità di test, lo script può essere eseguito in modalità reale per disabilitare effettivamente gli oggetti AD inattivi da più di 60 giorni.

## Comando di esempio:

```
.\Disable-StaleADObjects.ps1 -DaysInactive 60 -DryRun:\$false
```

- Disabilita gli account utente inattivi che non rientrano nelle esclusioni configurate.

- Disabilita i computer inattivi (solo PC/workstation, non server e non Domain Controller).

- Se specificato, sposta gli oggetti disabilitati nelle OU di quarantena.

- Aggiorna i file CSV di report e il log testuale dell-esecuzione.


## 3.3 Esempio con OU specifiche e OU di quarantena

È possibile limitare lo scope di ricerca e spostare gli oggetti disabilitati in OU dedicate, ad esempio:

.\Disable-StaleADObjects.ps1 `

-DaysInactive 60 `

-DryRun:\$false `

-UsersSearchBase "OU=Utenti,DC=azienda,DC=local" `

-ComputersSearchBase "OU=Workstations,DC=azienda,DC=local" `

-DisabledUsersOU "OU=Disabled Users,DC=azienda,DC=local" `

-DisabledComputersOU "OU=Disabled Computers,DC=azienda,DC=local"

## 4. Raccomandazioni operative

- Eseguire almeno uno o due DryRun prima dellattivazione automatica.

- Popolare in modo accurato le liste di esclusione per account di servizio, account applicativi e postazioni speciali.

- Evitare la gestione automatica degli account privilegiati: mantenerli sotto review manuale.

- Conservare i report CSV e i log per audit e rollback operativo.

- Valutare la distribuzione dello script tramite attività pianificata su un 
management server dedicato, non su tutte le macchine del dominio.
