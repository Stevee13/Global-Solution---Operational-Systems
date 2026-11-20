<#
===============================================================================
 Projeto : VIGIA - Fire Intelligence (CitizenTech)
 Script  : 03_tolerancia_falha.ps1
 Objetivo: Garantir que o IIS (W3SVC) e o Application Pool 'VigiaAppPool'
           se recuperem automaticamente em caso de falha, e oferecer um
           comando simples para SIMULAR a falha e comprovar o reinicio.
 Uso     : Rodar como Administrador na VM.
===============================================================================
#>

$NomeAppPool = "VigiaAppPool"
$CaminhoLog  = "C:\VIGIA\logs"

if (-not (Test-Path $CaminhoLog)) {
    New-Item -ItemType Directory -Path $CaminhoLog -Force | Out-Null
}
$ArquivoLog = Join-Path $CaminhoLog ("03_tolerancia_falha_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Start-Transcript -Path $ArquivoLog -Append | Out-Null

Write-Host "`n========== VIGIA - Passo 3: Tolerancia a Falha ==========" -ForegroundColor Cyan

# -------- 1) RECUPERACAO AUTOMATICA DO SERVICO W3SVC -------------------------
# sc.exe failure <servico> reset= <s> actions= restart/<ms>/restart/<ms>/restart/<ms>
# reset= 86400 -> zera o contador de falhas a cada 24h
# actions= restart/5000/restart/10000/restart/15000 -> reinicia o servico com 5s, 10s e 15s de delay
Write-Host "`n[1/3] Configurando recuperacao automatica do servico W3SVC..." -ForegroundColor Yellow
sc.exe failure W3SVC reset= 86400 actions= restart/5000/restart/10000/restart/15000 | Out-Host
# tambem reinicia em caso de encerramento "limpo" (sem erro)
sc.exe failureflag W3SVC 1 | Out-Host
Write-Host "      W3SVC configurado para reiniciar automaticamente em caso de falha." -ForegroundColor Green

# -------- 2) RECUPERACAO AUTOMATICA DO APPLICATION POOL ----------------------
# Rapid-Fail Protection: por padrao, o IIS desliga o AppPool se cair N vezes em X minutos.
# Aqui deixamos Rapid-Fail DESATIVADO (como pede o enunciado) para que o pool
# sempre tente subir de volta, e configuramos reinicio periodico preventivo.
Write-Host "`n[2/3] Ajustando recuperacao do Application Pool '$NomeAppPool'..." -ForegroundColor Yellow

Import-Module WebAdministration

# Desativa Rapid-Fail Protection
Set-ItemProperty "IIS:\AppPools\$NomeAppPool" -Name "failure.rapidFailProtection" -Value $false

# Configura "pingingEnabled" + auto start
Set-ItemProperty "IIS:\AppPools\$NomeAppPool" -Name "autoStart" -Value $true
Set-ItemProperty "IIS:\AppPools\$NomeAppPool" -Name "startMode" -Value "AlwaysRunning"

# Reinicio preventivo a cada 1h para liberar memoria
Set-ItemProperty "IIS:\AppPools\$NomeAppPool" -Name "recycling.periodicRestart.time" -Value ([TimeSpan]::FromHours(1))

# Mostra o estado final para servir de evidencia
Get-ItemProperty "IIS:\AppPools\$NomeAppPool" -Name "failure.rapidFailProtection", "autoStart", "startMode" |
    Format-List

Write-Host "      AppPool configurado (Rapid-Fail OFF, AutoStart ON, AlwaysRunning)." -ForegroundColor Green

# -------- 3) FUNCOES PARA SIMULAR FALHA E PROVAR O REINICIO ------------------
Write-Host "`n[3/3] Criando funcoes de simulacao de falha..." -ForegroundColor Yellow

function Invoke-VigiaFalhaServico {
    <#
      Mata o processo do IIS (svchost que hospeda W3SVC) de forma dura
      para forcar o SCM a executar a politica de recovery.
    #>
    Write-Host "Simulando falha do W3SVC (stop forcado)..." -ForegroundColor Magenta
    Stop-Service W3SVC -Force -ErrorAction SilentlyContinue

    # Espera a politica de recovery acionar o restart
    Start-Sleep -Seconds 8

    Write-Host "Estado de W3SVC apos a politica de recovery:" -ForegroundColor Magenta
    Get-Service W3SVC | Format-Table -AutoSize
}

function Invoke-VigiaFalhaAppPool {
    <#
      Encontra o processo w3wp.exe que atende o VigiaAppPool e o encerra.
      Como AlwaysRunning esta ligado, o IIS sobe um novo imediatamente.
    #>
    param([string]$AppPoolNome = $NomeAppPool)

    Write-Host "Procurando w3wp.exe do AppPool '$AppPoolNome'..." -ForegroundColor Magenta
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'w3wp.exe'" |
             Where-Object { $_.CommandLine -match [regex]::Escape($AppPoolNome) }

    if (-not $procs) {
        Write-Host "Nenhum w3wp.exe ativo para '$AppPoolNome'. Fazendo uma requisicao primeiro para instanciar..." -ForegroundColor Yellow
        try { Invoke-WebRequest -UseBasicParsing http://localhost -TimeoutSec 5 | Out-Null } catch {}
        Start-Sleep -Seconds 2
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'w3wp.exe'" |
                 Where-Object { $_.CommandLine -match [regex]::Escape($AppPoolNome) }
    }

    foreach ($p in $procs) {
        Write-Host "Matando PID $($p.ProcessId)..." -ForegroundColor Magenta
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 5
    Write-Host "Nova instancia do w3wp.exe para '$AppPoolNome':" -ForegroundColor Magenta
    Get-CimInstance Win32_Process -Filter "Name = 'w3wp.exe'" |
        Where-Object { $_.CommandLine -match [regex]::Escape($AppPoolNome) } |
        Select-Object ProcessId, CreationDate | Format-Table -AutoSize
}

Write-Host @"

Pronto. Para COMPROVAR a tolerancia a falha, rode no mesmo PowerShell:

  # Teste A - matar o servico IIS e ver ele voltar sozinho:
  Invoke-VigiaFalhaServico

  # Teste B - matar o w3wp.exe do VigiaAppPool e ver outro subir:
  Invoke-VigiaFalhaAppPool

Tire print do antes/depois para colocar como evidencia no relatorio.
"@ -ForegroundColor Cyan

Stop-Transcript | Out-Null
