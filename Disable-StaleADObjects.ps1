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

    # Percorso log
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

$RunDate   = Get-Date
$RunStamp  = $RunDate.ToString("yyyyMMdd-HHmmss")
$Cutoff    = $RunDate.AddDays(-$DaysInactive)

$UserCsv      = Join-Path $LogFolder "StaleUsers-$RunStamp.csv"
$ComputerCsv  = Join-Path $LogFolder "StaleComputers-$RunStamp.csv"
$ActionLog    = Join-Path $LogFolder "Actions-$RunStamp.log"

Start-Transcript -Path $ActionLog -Append | Out-Null

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Disabilitazione oggetti AD inattivi" -ForegroundColor Cyan
Write-Host "Cutoff inattività: $Cutoff" -ForegroundColor Yellow
Write-Host "DryRun: $DryRun" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Cyan

function Test-ExcludedUser {
    param([Microsoft.ActiveDirectory.Management.ADUser]$User)

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
    Filter      = 'Enabled -eq $true'
    Properties  = $userProps
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
            ObjectType           = "User"
            SamAccountName       = $u.SamAccountName
            Name                 = $u.Name
            Enabled              = $u.Enabled
            LastActivity         = $lastActivity
            LastLogonDate        = $u.LastLogonDate
            WhenCreated          = $u.whenCreated
            DistinguishedName    = $u.DistinguishedName
            Description          = $u.Description
            AdminCount           = $u.adminCount
            PasswordNeverExpires = $u.PasswordNeverExpires
        }
    }
}

$StaleUsers = $StaleUsers | Sort-Object LastActivity
$StaleUsers | Export-Csv -Path $UserCsv -NoTypeInformation -Encoding UTF8

Write-Host "Utenti candidati: $($StaleUsers.Count)" -ForegroundColor Yellow

foreach ($u in $StaleUsers) {
    Write-Host "Utente inattivo: $($u.SamAccountName) | LastActivity=$($u.LastActivity)" -ForegroundColor DarkYellow

    try {
        if ($DryRun) {
            Disable-ADAccount -Identity $u.SamAccountName -WhatIf
            if ($DisabledUsersOU -and $DisabledUsersOU.Trim() -ne "") {
                Write-Host "[DRYRUN] Move-ADObject '$($u.DistinguishedName)' -> '$DisabledUsersOU'"
            }
        }
        else {
            Disable-ADAccount -Identity $u.SamAccountName -Confirm:$false

            if ($DisabledUsersOU -and $DisabledUsersOU.Trim() -ne "") {
                Move-ADObject -Identity $u.DistinguishedName -TargetPath $DisabledUsersOU -Confirm:$false
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
    Filter      = 'Enabled -eq $true'
    Properties  = $computerProps
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
            ObjectType         = "Computer"
            SamAccountName     = $c.SamAccountName
            Name               = $c.Name
            Enabled            = $c.Enabled
            LastActivity       = $lastActivity
            LastLogonDate      = $c.LastLogonDate
            WhenCreated        = $c.whenCreated
            OperatingSystem    = $c.OperatingSystem
            DistinguishedName  = $c.DistinguishedName
            Description        = $c.Description
        }
    }
}

$StaleComputers = $StaleComputers | Sort-Object LastActivity
$StaleComputers | Export-Csv -Path $ComputerCsv -NoTypeInformation -Encoding UTF8

Write-Host "Computer candidati: $($StaleComputers.Count)" -ForegroundColor Yellow

foreach ($c in $StaleComputers) {
    Write-Host "Computer inattivo: $($c.Name) | LastActivity=$($c.LastActivity)" -ForegroundColor DarkYellow

    try {
        if ($DryRun) {
            Disable-ADAccount -Identity $c.SamAccountName -WhatIf
            if ($DisabledComputersOU -and $DisabledComputersOU.Trim() -ne "") {
                Write-Host "[DRYRUN] Move-ADObject '$($c.DistinguishedName)' -> '$DisabledComputersOU'"
            }
        }
        else {
            Disable-ADAccount -Identity $c.SamAccountName -Confirm:$false

            if ($DisabledComputersOU -and $DisabledComputersOU.Trim() -ne "") {
                Move-ADObject -Identity $c.DistinguishedName -TargetPath $DisabledComputersOU -Confirm:$false
            }

            Write-Host "Disabilitato computer: $($c.Name)" -ForegroundColor Red
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