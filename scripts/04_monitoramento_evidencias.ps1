<#
===============================================================================
 Projeto : VIGIA - Fire Intelligence (CitizenTech)
 Script  : 04_monitoramento_evidencias.ps1
 Objetivo: Criar um Data Collector Set no Performance Monitor com alertas
           de CPU, Memoria e Disco, e gerar o arquivo 'evidencias_rede.txt'
           com ipconfig /all, nslookup e Test-NetConnection.
 Uso     : Rodar como Administrador na VM.
===============================================================================
#>

$NomeDCS       = "VIGIA_Alertas"
$PastaEvidenc  = "C:\VIGIA\evidencias"
$PastaLog      = "C:\VIGIA\logs"
$DominioFQDN   = "vigia.local"
$AlvoPing      = "8.8.8.8"

foreach ($p in @($PastaEvidenc, $PastaLog)) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

$ArquivoLog    = Join-Path $PastaLog ("04_monitoramento_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$ArquivoEvid   = Join-Path $PastaEvidenc "evidencias_rede.txt"

Start-Transcript -Path $ArquivoLog -Append | Out-Null
Write-Host "`n========== VIGIA - Passo 4: Monitoramento + Evidencias ==========" -ForegroundColor Cyan

# -------- 1) DATA COLLECTOR SET DE ALERTA ------------------------------------
# Cria um DCS do tipo "Alert" via logman:
#   -> dispara um evento no log do Windows quando CPU > 85%, RAM livre < 500MB
#      ou disco C: com <10% livre.
Write-Host "`n[1/2] Criando Data Collector Set '$NomeDCS' com alertas de CPU, RAM e Disco..." -ForegroundColor Yellow

# Remove set antigo se existir (idempotente)
logman stop  $NomeDCS 2>$null | Out-Null
logman delete $NomeDCS 2>$null | Out-Null

# Cria o alerta multi-contador.
#  -si  = intervalo de amostragem (seg)
#  -th  = threshold (counter > valor)
#  -ep  = cria uma entrada no log de eventos quando dispara
logman create alert $NomeDCS `
    -th "\Processor(_Total)\% Processor Time>85" `
         "\Memory\Available MBytes<500" `
         "\LogicalDisk(C:)\% Free Space<10" `
    -si 15 -ep | Out-Host

logman start $NomeDCS | Out-Host

Write-Host "      DCS '$NomeDCS' criado e iniciado." -ForegroundColor Green
Write-Host "      Para ver: perfmon -> Data Collector Sets -> User Defined -> $NomeDCS" -ForegroundColor Green

# -------- 2) EVIDENCIAS DE REDE ----------------------------------------------
Write-Host "`n[2/2] Coletando evidencias de rede em '$ArquivoEvid'..." -ForegroundColor Yellow

$Cabecalho = @"
===============================================================================
 VIGIA - Fire Intelligence | Evidencias de Rede
 Gerado em: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
 Host     : $env:COMPUTERNAME
 Usuario  : $env:USERDOMAIN\$env:USERNAME
===============================================================================
"@
Set-Content -Path $ArquivoEvid -Value $Cabecalho -Encoding UTF8

function Add-Secao {
    param([string]$Titulo, [scriptblock]$Comando)
    Add-Content -Path $ArquivoEvid -Value "`r`n----- $Titulo -----`r`n"
    try {
        $saida = & $Comando 2>&1 | Out-String
    } catch {
        $saida = "ERRO: $_"
    }
    Add-Content -Path $ArquivoEvid -Value $saida
}

Add-Secao "ipconfig /all"                 { ipconfig /all }
Add-Secao "nslookup $DominioFQDN"         { nslookup $DominioFQDN }
Add-Secao "Test-NetConnection $AlvoPing"  { Test-NetConnection -ComputerName $AlvoPing -InformationLevel Detailed }
Add-Secao "Test-NetConnection $DominioFQDN -Port 80" {
    Test-NetConnection -ComputerName $DominioFQDN -Port 80 -InformationLevel Detailed
}
Add-Secao "Get-Service W3SVC"             { Get-Service W3SVC | Format-List * }
Add-Secao "Get-WebAppPoolState VigiaAppPool" {
    try { Import-Module WebAdministration; Get-WebAppPoolState -Name VigiaAppPool } catch { "IIS nao instalado ou AppPool inexistente." }
}

Write-Host "      Evidencias salvas em: $ArquivoEvid" -ForegroundColor Green
Write-Host "      (Anexe este arquivo no relatorio de entrega.)" -ForegroundColor Green

Stop-Transcript | Out-Null

Write-Host "`nTodos os passos VIGIA concluidos. Boa entrega!" -ForegroundColor Cyan
