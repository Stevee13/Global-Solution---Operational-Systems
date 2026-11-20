<#
===============================================================================
 Projeto : VIGIA - Fire Intelligence (CitizenTech)
 Script  : 01_rede_ad_dns.ps1
 Objetivo: Configurar IP fixo, hostname, instalar/promover AD DS e DNS local
           para o dominio vigia.local.
 Uso     : Abrir o PowerShell COMO ADMINISTRADOR dentro da VM Windows Server
           e executar este script. A VM reinicia ao final da promocao do DC.
 Observ. : Execute em uma Windows Server (nao em Windows 10/11). Ao terminar,
           abra uma nova sessao, faca login com <DOMINIO>\Administrator e
           rode o passo 2 (IIS/NTFS/GPO).
===============================================================================
#>

# -------- VARIAVEIS DO AMBIENTE (ajuste se necessario) ------------------------
$NovoHostname      = "SRV-VIGIA"
$DominioFQDN       = "vigia.local"
$DominioNetBIOS    = "VIGIA"
$NomeInterface     = "Ethernet"                # ajuste para o nome real do adaptador (Get-NetAdapter)
$IPFixo            = "192.168.56.10"
$MascaraPrefixo    = 24                        # 24 = 255.255.255.0
$GatewayPadrao     = "192.168.56.1"
$DNSPreferencial   = "127.0.0.1"               # o proprio servidor quando virar DC/DNS
$CaminhoLog        = "C:\VIGIA\logs"

# -------- BOOTSTRAP: pasta de log e transcript --------------------------------
if (-not (Test-Path $CaminhoLog)) {
    New-Item -ItemType Directory -Path $CaminhoLog -Force | Out-Null
}
$ArquivoLog = Join-Path $CaminhoLog ("01_rede_ad_dns_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Start-Transcript -Path $ArquivoLog -Append | Out-Null

Write-Host "`n========== VIGIA - Passo 1: Rede + AD DS + DNS ==========" -ForegroundColor Cyan

# -------- VERIFICACOES BASICAS ------------------------------------------------
# Confirma que estamos rodando como Administrador
$IdentidadeAtual = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $IdentidadeAtual.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Execute este script em um PowerShell elevado (Run as Administrator)."
    Stop-Transcript | Out-Null
    return
}

# Confirma que e Windows Server (AD DS nao instala em cliente)
$ProdutoOS = (Get-CimInstance Win32_OperatingSystem).ProductType
# ProductType: 1 = Workstation, 2 = DC, 3 = Server
if ($ProdutoOS -eq 1) {
    Write-Error "Esta maquina nao e Windows Server. Rode este script dentro da VM Windows Server."
    Stop-Transcript | Out-Null
    return
}

# -------- 1) CONFIGURAR HOSTNAME ---------------------------------------------
$HostnameAtual = $env:COMPUTERNAME
Write-Host "`n[1/4] Hostname atual: $HostnameAtual" -ForegroundColor Yellow
if ($HostnameAtual -ne $NovoHostname) {
    Write-Host "      Renomeando para: $NovoHostname (reinicio sera feito apos a promocao do DC)" -ForegroundColor Yellow
    Rename-Computer -NewName $NovoHostname -Force -ErrorAction Stop
} else {
    Write-Host "      Hostname ja esta correto. Nada a fazer." -ForegroundColor Green
}

# -------- 2) CONFIGURAR IP FIXO + GATEWAY + DNS ------------------------------
Write-Host "`n[2/4] Configurando IP fixo em '$NomeInterface' ($IPFixo/$MascaraPrefixo, GW $GatewayPadrao, DNS $DNSPreferencial)" -ForegroundColor Yellow

# Garante que a interface existe
$Adaptador = Get-NetAdapter -Name $NomeInterface -ErrorAction SilentlyContinue
if (-not $Adaptador) {
    Write-Error "Adaptador '$NomeInterface' nao encontrado. Use Get-NetAdapter para ver o nome correto e ajuste a variavel \$NomeInterface."
    Stop-Transcript | Out-Null
    return
}

# Remove IP/GW/DNS antigos (ignora erro se nao houver)
Get-NetIPAddress -InterfaceAlias $NomeInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

Get-NetRoute -InterfaceAlias $NomeInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

# Aplica configuracao nova
New-NetIPAddress `
    -InterfaceAlias $NomeInterface `
    -IPAddress $IPFixo `
    -PrefixLength $MascaraPrefixo `
    -DefaultGateway $GatewayPadrao `
    -AddressFamily IPv4 `
    -ErrorAction Stop | Out-Null

Set-DnsClientServerAddress -InterfaceAlias $NomeInterface -ServerAddresses $DNSPreferencial

Write-Host "      IP aplicado. Conferindo:" -ForegroundColor Green
Get-NetIPAddress -InterfaceAlias $NomeInterface -AddressFamily IPv4 |
    Select-Object InterfaceAlias, IPAddress, PrefixLength | Format-Table -AutoSize

# -------- 3) INSTALAR AD DS + DNS + FERRAMENTAS ------------------------------
Write-Host "`n[3/4] Instalando funcoes AD DS, DNS e ferramentas RSAT..." -ForegroundColor Yellow
Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools -ErrorAction Stop | Out-Null
Write-Host "      Funcoes instaladas." -ForegroundColor Green

# -------- 4) PROMOVER O SERVIDOR A CONTROLADOR DE DOMINIO --------------------
Write-Host "`n[4/4] Promovendo o servidor a Controlador de Dominio para '$DominioFQDN'" -ForegroundColor Yellow
Write-Warning "A senha do modo de restauracao (DSRM) sera solicitada agora. GUARDE-A."

$SenhaDSRM = Read-Host -AsSecureString "Digite a senha DSRM (Directory Services Restore Mode)"

Import-Module ADDSDeployment

Install-ADDSForest `
    -DomainName $DominioFQDN `
    -DomainNetbiosName $DominioNetBIOS `
    -DomainMode "WinThreshold" `
    -ForestMode "WinThreshold" `
    -InstallDns:$true `
    -SafeModeAdministratorPassword $SenhaDSRM `
    -CreateDnsDelegation:$false `
    -DatabasePath "C:\Windows\NTDS" `
    -LogPath "C:\Windows\NTDS" `
    -SysvolPath "C:\Windows\SYSVOL" `
    -NoRebootOnCompletion:$false `
    -Force:$true

# Observacao: o cmdlet acima dispara reinicio automatico.
# Depois do reboot, faca login como VIGIA\Administrator e rode o script 02.

Stop-Transcript | Out-Null
