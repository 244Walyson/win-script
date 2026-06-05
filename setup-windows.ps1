#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Instala Docker via WSL2 e configura Moura Automation para iniciar automaticamente.
    Se o PC reiniciar no meio da instalacao, continua automaticamente apos o login.
.NOTES
    Execute no PowerShell como Administrador:
    powershell -ExecutionPolicy Bypass -File setup-windows.ps1
#>
param(
    [switch]$Resumed  # Passado automaticamente ao retomar apos reinicio
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# Localização permanente do script (sobrevive ao reinicio)
$ScriptInstallDir  = "C:\ProgramData\MouraAutomation"
$ScriptInstallPath = "$ScriptInstallDir\setup-windows.ps1"
$ResumeTaskName    = "MouraSetupResume"
$FinalTaskName     = "MouraAutomationDocker"

function Write-Step { param($n, $msg) Write-Host "`n[$n/6] $msg" -ForegroundColor Yellow }
function Write-OK   { param($msg)     Write-Host "  [OK] $msg"   -ForegroundColor Green  }
function Write-Info { param($msg)     Write-Host "       $msg"   -ForegroundColor Cyan   }
function Write-Warn { param($msg)     Write-Host "  [!]  $msg"   -ForegroundColor Yellow }

function Write-BashScript {
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}

function ConvertTo-WslPath {
    param([string]$WindowsPath)
    $result = & wsl wslpath -u ($WindowsPath.Replace("\", "/")) 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Falha ao converter path: $WindowsPath" }
    return $result.Trim()
}

# ─────────────────────────────────────────────────────────────────────────────
# Se estamos retomando apos reinicio: remove a tarefa de resume e avisa
# ─────────────────────────────────────────────────────────────────────────────
if ($Resumed) {
    Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "=======================================" -ForegroundColor Cyan
    Write-Host "   Continuando instalacao apos reboot  " -ForegroundColor Cyan
    Write-Host "=======================================" -ForegroundColor Cyan
} else {
    Write-Host ""
    Write-Host "=======================================" -ForegroundColor Cyan
    Write-Host "   Moura Automation - Setup Windows    " -ForegroundColor Cyan
    Write-Host "=======================================" -ForegroundColor Cyan
}

# ─────────────────────────────────────────────────────────────────────────────
# Salva o script em local permanente (para poder ser chamado apos reinicio)
# ─────────────────────────────────────────────────────────────────────────────
if (-not (Test-Path $ScriptInstallDir)) {
    New-Item -ItemType Directory -Path $ScriptInstallDir -Force | Out-Null
}
if ($PSCommandPath -and ($PSCommandPath -ne $ScriptInstallPath)) {
    Copy-Item -Path $PSCommandPath -Destination $ScriptInstallPath -Force
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Verifica versão do Windows
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 1 "Verificando compatibilidade do sistema..."

$build = [System.Environment]::OSVersion.Version.Build
if ($build -lt 18362) {
    Write-Host "`n  ERRO: Windows 10 build 18362 (versao 1903) ou superior necessario." -ForegroundColor Red
    Write-Host "  Build detectado: $build" -ForegroundColor Red
    exit 1
}
Write-OK "Windows compativel (build $build)"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Habilita WSL2 (com auto-resume se precisar reiniciar)
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 2 "Habilitando WSL2..."

$wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
$vmFeature  = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
$needsReboot = $false

if ($wslFeature.State -ne "Enabled") {
    Write-Info "Habilitando Windows Subsystem for Linux..."
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart | Out-Null
    $needsReboot = $true
} else {
    Write-Info "WSL ja habilitado"
}

if ($vmFeature.State -ne "Enabled") {
    Write-Info "Habilitando Virtual Machine Platform..."
    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart | Out-Null
    $needsReboot = $true
} else {
    Write-Info "VirtualMachinePlatform ja habilitado"
}

if ($needsReboot) {
    Write-Warn "Reinicio necessario. Agendando continuacao automatica apos o login..."

    # Cria tarefa que retoma o script automaticamente apos o proximo login
    $resumeAction = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -File `"$ScriptInstallPath`" -Resumed"

    $resumeTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

    $resumeSettings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    $resumePrincipal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive `
        -RunLevel Highest

    Register-ScheduledTask `
        -TaskName $ResumeTaskName `
        -Action $resumeAction `
        -Trigger $resumeTrigger `
        -Settings $resumeSettings `
        -Principal $resumePrincipal `
        -Description "Continua instalacao Moura Automation apos reinicio" `
        -Force | Out-Null

    Write-OK "Tarefa de retomada registrada. Reiniciando em 5 segundos..."
    Start-Sleep -Seconds 5
    Restart-Computer -Force
    exit 0
}

& wsl --set-default-version 2 2>&1 | Out-Null
Write-OK "WSL2 configurado como padrao"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Instala Ubuntu 22.04
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 3 "Instalando Ubuntu 22.04 no WSL2..."

$distroName = "Ubuntu-22.04"
$distros    = & wsl -l -q 2>&1
$hasDistro  = $distros | Where-Object { $_ -replace "`0","" -match "Ubuntu-22.04" }

if (-not $hasDistro) {
    Write-Info "Baixando Ubuntu 22.04 (pode demorar alguns minutos)..."
    & wsl --install -d Ubuntu-22.04 --no-launch 2>&1
    Start-Sleep -Seconds 20

    Write-Info "Inicializando Ubuntu..."
    $initResult = & wsl -d $distroName -u root -- echo "ok" 2>&1
    if ($initResult -notmatch "ok") {
        Write-Warn "Ubuntu-22.04 falhou, tentando Ubuntu generico..."
        $distroName = "Ubuntu"
        & wsl --install -d Ubuntu --no-launch 2>&1 | Out-Null
        Start-Sleep -Seconds 15
        & wsl -d $distroName -u root -- echo "ok" 2>&1 | Out-Null
    }
    Write-OK "Ubuntu instalado: $distroName"
} else {
    # Confirma qual distro responde (Ubuntu-22.04 ou Ubuntu)
    $initResult = & wsl -d $distroName -u root -- echo "ok" 2>&1
    if ($initResult -notmatch "ok") { $distroName = "Ubuntu" }
    Write-OK "Ubuntu ja instalado: $distroName"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Instala Docker Engine (com recuperacao de dpkg quebrado)
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 4 "Instalando Docker Engine no Ubuntu..."

$dockerCheck = & wsl -d $distroName -u root -- which docker 2>&1
if ($dockerCheck -match "docker") {
    Write-OK "Docker ja instalado"
} else {
    Write-Info "Instalando Docker Engine (aguarde 3-5 min)..."

    $installScript = @'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# Recupera instalacao interrompida (caso script tenha sido interrompido antes)
dpkg --configure -a 2>/dev/null || true
apt-get install -f -y -qq 2>/dev/null || true

apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $CODENAME stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io

echo "Docker instalado: $(docker --version)"
'@

    $scriptFile   = "$env:TEMP\install-docker.sh"
    Write-BashScript -Path $scriptFile -Content $installScript
    $wslScriptPath = ConvertTo-WslPath $scriptFile
    & wsl -d $distroName -u root -- bash $wslScriptPath
    Write-OK "Docker Engine instalado"
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Configura wsl.conf + escreve arquivos + sobe stack via Docker Compose
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 5 "Configurando Docker e iniciando Moura Automation..."

# Detecta se o WSL suporta systemd (versao 0.67.6 ou superior)
$systemdSupported = $false
try {
    $wslVer = & wsl --version 2>&1 | Select-String "WSL version:" | ForEach-Object { $_ -replace "WSL version:\s*","" -replace "\s.*","" }
    if ($wslVer -match "^(\d+)\.(\d+)") {
        $major = [int]$Matches[1]; $minor = [int]$Matches[2]
        if ($major -gt 0 -or $minor -ge 67) { $systemdSupported = $true }
    }
} catch {}

if ($systemdSupported) {
    Write-Info "WSL suporta systemd — usando systemd para inicializacao confiavel do Docker"
    $wslConf = "[boot]`nsystemd=true`n"
} else {
    Write-Warn "WSL sem suporte a systemd — usando boot command com retry"
    $wslConf = @"
[boot]
command = /bin/bash -c 'for i in 1 2 3 4 5; do service docker start && break || sleep 3; done >> /var/log/moura-boot.log 2>&1; sleep 5; docker compose -f /opt/moura/docker-compose.yml up -d >> /var/log/moura-boot.log 2>&1 || true'
"@
}

$wslConfFile = "$env:TEMP\wsl.conf"
Write-BashScript -Path $wslConfFile -Content $wslConf
& wsl -d $distroName -u root -- cp (ConvertTo-WslPath $wslConfFile) /etc/wsl.conf
Write-Info "/etc/wsl.conf configurado"

# docker-compose.yml para Windows (usa imagens pre-construidas do Docker Hub)
$composeContent = @'
services:
  postgres:
    image: postgres:16-alpine
    container_name: bank_statements_postgres
    environment:
      POSTGRES_USER: moura
      POSTGRES_PASSWORD: moura123
      POSTGRES_DB: mouradb
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "54320:5432"
    networks:
      - app-network
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U moura -d mouradb"]
      interval: 10s
      timeout: 5s
      retries: 5

  db-init:
    image: walymb/bank-statements-backup:latest
    container_name: bank_statements_db_init
    environment:
      DATABASE_URL: postgres://moura:moura123@postgres:5432/mouradb
    command: ["/usr/local/bin/restore.sh"]
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - app-network
    restart: "no"

  db-backup:
    image: walymb/bank-statements-backup:latest
    container_name: bank_statements_db_backup
    environment:
      DATABASE_URL: postgres://moura:moura123@postgres:5432/mouradb
      BACKUP_SCHEDULE: "0 */6 * * *"
    command: ["/usr/local/bin/entrypoint.sh"]
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - app-network
    restart: unless-stopped

  api:
    image: walymb/bank-statements-api:latest
    container_name: bank_statements_api
    environment:
      DATABASE_URL: postgres://moura:moura123@postgres:5432/mouradb
      PORT: 3001
      JWT_SECRET: moura-silva-jwt-secret-key-change-in-production-2026
    ports:
      - "3001:3001"
    depends_on:
      postgres:
        condition: service_healthy
      db-init:
        condition: service_completed_successfully
    networks:
      - app-network
    restart: unless-stopped

  frontend:
    image: walymb/bank-statements-frontend:local
    container_name: bank_statements_frontend
    ports:
      - "8090:80"
    depends_on:
      - api
    networks:
      - app-network
    restart: unless-stopped

networks:
  app-network:
    driver: bridge

volumes:
  postgres_data:
'@

# Salva docker-compose em temp e copia para /opt/moura no WSL
$composeFile = "$env:TEMP\moura-compose.yml"
Write-BashScript -Path $composeFile -Content $composeContent

& wsl -d $distroName -u root -- mkdir -p /opt/moura
& wsl -d $distroName -u root -- cp (ConvertTo-WslPath $composeFile) /opt/moura/docker-compose.yml
Write-Info "Arquivos copiados para /opt/moura"

# Instala docker-compose-plugin + habilita servico + baixa imagens + sobe stack
$runScript = @"
#!/bin/bash
set -e

# Inicia Docker com retry (necessario no primeiro boot apos wsl --shutdown)
for i in 1 2 3 4 5; do
    service docker start 2>/dev/null && break
    echo "Tentativa \$i falhou, aguardando..."
    sleep 3
done

# Aguarda daemon ficar pronto
for i in \$(seq 1 15); do
    docker info > /dev/null 2>&1 && break
    echo "Aguardando Docker daemon... (\$i/15)"
    sleep 2
done

if ! docker info > /dev/null 2>&1; then
    echo "ERRO: Docker daemon nao respondeu. Verifique: journalctl -u docker ou /var/log/docker.log"
    exit 1
fi

if ! docker compose version > /dev/null 2>&1; then
    echo "Instalando docker compose plugin..."
    apt-get install -y -qq docker-compose-plugin 2>/dev/null || true
fi

$(if ($systemdSupported) { "# systemd: habilita Docker para iniciar automaticamente no boot do WSL" + [Environment]::NewLine + "systemctl enable docker 2>/dev/null || true" })

echo "Baixando imagens..."
docker compose -f /opt/moura/docker-compose.yml pull

echo "Subindo stack..."
docker compose -f /opt/moura/docker-compose.yml up -d
"@

$runFile = "$env:TEMP\run-moura.sh"
Write-BashScript -Path $runFile -Content $runScript
& wsl -d $distroName -u root -- bash (ConvertTo-WslPath $runFile)
Write-OK "Stack em execucao"

# ─────────────────────────────────────────────────────────────────────────────
# 6. Task Scheduler — sobe Docker ao fazer login (uso permanente, sem janela)
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 6 "Registrando inicializacao automatica permanente..."

Unregister-ScheduledTask -TaskName $FinalTaskName -Confirm:$false -ErrorAction SilentlyContinue

if ($systemdSupported) {
    # Com systemd o Docker ja inicia sozinho via WSL boot — apenas precisamos
    # garantir que o WSL inicie no login (o que acontece assim que qualquer wsl
    # command e executado). Registramos uma tarefa minima que acorda o WSL.
    $vbsContent = "CreateObject(`"WScript.Shell`").Run `"wsl -d $distroName -u root -- echo ok`", 0, False"
    $vbsPath = "$ScriptInstallDir\start-docker.vbs"
    [IO.File]::WriteAllText($vbsPath, $vbsContent, [Text.UTF8Encoding]::new($false))
    Write-Info "systemd cuida do Docker automaticamente; tarefa acorda o WSL no login"
} else {
    # Sem systemd: script bash com retry para docker + compose up
    $startupBash = @'
#!/bin/bash
for i in 1 2 3 4 5; do
    service docker start 2>/dev/null && break
    sleep 3
done
for i in $(seq 1 15); do
    docker info > /dev/null 2>&1 && break
    sleep 2
done
docker compose -f /opt/moura/docker-compose.yml up -d >> /var/log/moura-boot.log 2>&1 || true
'@
    $startupFile = "$ScriptInstallDir\startup.sh"
    Write-BashScript -Path $startupFile -Content $startupBash
    $wslStartupPath = ConvertTo-WslPath $startupFile
    & wsl -d $distroName -u root -- chmod +x $wslStartupPath 2>&1 | Out-Null

    $vbsContent = "CreateObject(`"WScript.Shell`").Run `"wsl -d $distroName -u root -- bash $wslStartupPath`", 0, False"
    $vbsPath = "$ScriptInstallDir\start-docker.vbs"
    [IO.File]::WriteAllText($vbsPath, $vbsContent, [Text.UTF8Encoding]::new($false))
    Write-Info "Script de startup com retry criado: $vbsPath"
}

$action = New-ScheduledTaskAction `
    -Execute "wscript.exe" `
    -Argument "`"$vbsPath`""

$trigger  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest

Register-ScheduledTask `
    -TaskName $FinalTaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Inicia Docker no WSL2 para Moura Automation ao fazer login (sem janela)" `
    -Force | Out-Null

Write-OK "Tarefa permanente registrada: $FinalTaskName"

# ─────────────────────────────────────────────────────────────────────────────
# Conclusao
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=======================================" -ForegroundColor Green
Write-Host "      INSTALACAO CONCLUIDA!            " -ForegroundColor Green
Write-Host "=======================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Aplicacao: http://localhost:8090" -ForegroundColor Cyan
Write-Host ""
Write-Host "  - Inicia automaticamente ao fazer login no Windows" -ForegroundColor White
Write-Host "  - Nao depende do Docker Desktop" -ForegroundColor White
Write-Host "  - Dados persistidos no volume 'moura_pgdata'" -ForegroundColor White
Write-Host ""
Write-Host "  Comandos uteis:" -ForegroundColor Gray
Write-Host "    Ver logs:   wsl -d $distroName -u root -- docker compose -f /opt/moura/docker-compose.yml logs -f" -ForegroundColor Gray
Write-Host "    Parar:      wsl -d $distroName -u root -- docker compose -f /opt/moura/docker-compose.yml down" -ForegroundColor Gray
Write-Host "    Reiniciar:  wsl -d $distroName -u root -- docker compose -f /opt/moura/docker-compose.yml restart" -ForegroundColor Gray
Write-Host ""
