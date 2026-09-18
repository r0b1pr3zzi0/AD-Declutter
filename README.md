# AD-Declutter - Disabilitazione automatica di utenti e computer AD inattivi oltre 60 giorni

Documento operativo per l’utilizzo di uno script PowerShell che identifica e disabilita oggetti Active Directory (utenti e PC) inattivi da oltre 60 giorni, con modalità di test e modalità reale.

## 1. Descrizione script PowerShell

- Lo script cerca account utente e computer abilitati che risultano inattivi da più di 60 giorni.

- Per stimare l'inattività usa il campo LastLogonDate; se non disponibile, usa whenCreated come fallback per gli oggetti mai utilizzati.

- Per motivi di sicurezza, esclude gli account critici di default: Administrator, Guest e krbtgt.

- Esclude anche gli account con adminCount=1, così da non disabilitare automaticamente account privilegiati o protetti.

- Per i computer, esclude i Domain Controller e i server, limitando l-azione ai PC/workstation.

- Genera tre file di log: elenco utenti candidati, elenco computer candidati e transcript delle azioni.

- Supporta una modalità DryRun (test) per verificare l'impatto prima dell'esecuzione reale.

- Facoltativamente può spostare gli oggetti disabilitati in OU dedicate di quarantena.

Nota importante: LastLogonDate/lastLogonTimestamp in Active Directory non è un indicatore in tempo reale. Prima di attivare la disabilitazione automatica in produzione è consigliata una fase di validazione in DryRun e un controllo delle eccezioni (account di servizio, account condivisi, postazioni speciali, dispositivi di reparto, ecc.).

## 2. Script PowerShell completo

Scaricare e salvare il file con nome suggerito Disable-StaleADObjects.ps1 e verificarne prima l’esecuzione in ambiente di test o in modalità DryRun.

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

- Eseguire almeno uno o due DryRun prima dell'attivazione automatica.

- Popolare in modo accurato le liste di esclusione per account di servizio, account applicativi e postazioni speciali.

- Evitare la gestione automatica degli account privilegiati: mantenerli sotto review manuale.

- Conservare i report CSV e i log per audit e rollback operativo.

- Valutare la distribuzione dello script tramite attività pianificata su un 
management server dedicato, non su tutte le macchine del dominio.
