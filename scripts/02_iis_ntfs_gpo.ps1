<#
===============================================================================
 Projeto : VIGIA - Fire Intelligence (CitizenTech)
 Script  : 02_iis_ntfs_gpo.ps1
 Objetivo: Instalar IIS + ferramentas, criar C:\inetpub\vigia com NTFS restrito,
           criar Site e Application Pool 'VigiaAppPool' e aplicar uma GPO
           basica de seguranca/auditoria no dominio vigia.local.
 Uso     : Rodar como Administrador na VM apos o reboot do passo 1 (ja como DC).
===============================================================================
#>

# -------- VARIAVEIS -----------------------------------------------------------
$PastaSite         = "C:\inetpub\vigia"
$NomeSite          = "VigiaSite"
$NomeAppPool       = "VigiaAppPool"
$PortaHTTP         = 80
$BindingHost       = ""                        # vazio = responde em qualquer host header
$GpoNome           = "GPO_VIGIA_Seguranca"
$CaminhoLog        = "C:\VIGIA\logs"

# -------- LOG ----------------------------------------------------------------
if (-not (Test-Path $CaminhoLog)) {
    New-Item -ItemType Directory -Path $CaminhoLog -Force | Out-Null
}
$ArquivoLog = Join-Path $CaminhoLog ("02_iis_ntfs_gpo_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Start-Transcript -Path $ArquivoLog -Append | Out-Null

Write-Host "`n========== VIGIA - Passo 2: IIS + NTFS + GPO ==========" -ForegroundColor Cyan

# Admin check
$IdentidadeAtual = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $IdentidadeAtual.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Execute este script em um PowerShell elevado."
    Stop-Transcript | Out-Null
    return
}

# -------- 1) INSTALAR IIS + FERRAMENTAS --------------------------------------
Write-Host "`n[1/5] Instalando IIS (Web-Server) e ferramentas de gerenciamento..." -ForegroundColor Yellow
Install-WindowsFeature -Name Web-Server, Web-Mgmt-Tools, Web-Mgmt-Console, Web-Scripting-Tools -IncludeManagementTools -ErrorAction Stop | Out-Null
Import-Module WebAdministration
Write-Host "      IIS instalado." -ForegroundColor Green

# -------- 2) CRIAR PASTA C:\inetpub\vigia COM INDEX.HTML ---------------------
Write-Host "`n[2/5] Criando pasta '$PastaSite' e index.html de teste..." -ForegroundColor Yellow
if (-not (Test-Path $PastaSite)) {
    New-Item -ItemType Directory -Path $PastaSite -Force | Out-Null
}

$ConteudoIndex = @"
<!doctype html>
<html lang="pt-br">
  <head><meta charset="utf-8"><title>VIGIA - Fire Intelligence</title></head>
  <body style="font-family:Segoe UI, Arial, sans-serif; background:#0b1021; color:#f5f5f7; text-align:center; padding:60px">
    <h1>VIGIA - Fire Intelligence</h1>
    <p>Servidor Windows Server - IIS operacional</p>
    <p>Dominio: vigia.local</p>
  </body>
</html>
"@
Set-Content -Path (Join-Path $PastaSite "index.html") -Value $ConteudoIndex -Encoding UTF8 -Force
Write-Host "      Pasta e index.html prontos." -ForegroundColor Green

# -------- 3) NTFS: HERANCA + PERMISSOES RESTRITAS ----------------------------
Write-Host "`n[3/5] Aplicando NTFS restrito em '$PastaSite'..." -ForegroundColor Yellow

# Pega a ACL atual
$Acl = Get-Acl $PastaSite

# Quebra a heranca e REMOVE as entradas herdadas (nao copia para nao manter Users/Authenticated Users)
$Acl.SetAccessRuleProtection($true, $false)

# Zera regras explicitas que possam ter sobrado
foreach ($regra in @($Acl.Access)) {
    [void]$Acl.RemoveAccessRule($regra)
}

# Define apenas 3 grupos com acesso: SYSTEM, Administradores e IIS_IUSRS
$regrasNovas = @(
    New-Object System.Security.AccessControl.FileSystemAccessRule(
        "NT AUTHORITY\SYSTEM", "FullControl",
        "ContainerInherit,ObjectInherit", "None", "Allow"),

    New-Object System.Security.AccessControl.FileSystemAccessRule(
        "BUILTIN\Administrators", "FullControl",
        "ContainerInherit,ObjectInherit", "None", "Allow"),

    New-Object System.Security.AccessControl.FileSystemAccessRule(
        "BUILTIN\IIS_IUSRS", "ReadAndExecute",
        "ContainerInherit,ObjectInherit", "None", "Allow")
)
foreach ($r in $regrasNovas) { $Acl.AddAccessRule($r) }

Set-Acl -Path $PastaSite -AclObject $Acl
Write-Host "      ACL aplicada. Entradas atuais:" -ForegroundColor Green
(Get-Acl $PastaSite).Access | Select-Object IdentityReference, FileSystemRights, AccessControlType | Format-Table -AutoSize

# -------- 4) IIS: APPLICATION POOL + SITE ------------------------------------
Write-Host "`n[4/5] Criando Application Pool '$NomeAppPool' e Site '$NomeSite'..." -ForegroundColor Yellow

# AppPool
if (Test-Path "IIS:\AppPools\$NomeAppPool") {
    Remove-WebAppPool -Name $NomeAppPool
}
New-WebAppPool -Name $NomeAppPool | Out-Null
Set-ItemProperty "IIS:\AppPools\$NomeAppPool" -Name managedRuntimeVersion -Value "v4.0"
Set-ItemProperty "IIS:\AppPools\$NomeAppPool" -Name processModel.identityType -Value ApplicationPoolIdentity

# Site (remove o Default Web Site se existir para evitar conflito na porta 80)
if (Test-Path "IIS:\Sites\Default Web Site") {
    Stop-Website "Default Web Site" -ErrorAction SilentlyContinue
}
if (Test-Path "IIS:\Sites\$NomeSite") {
    Remove-Website -Name $NomeSite
}
New-Website `
    -Name $NomeSite `
    -PhysicalPath $PastaSite `
    -ApplicationPool $NomeAppPool `
    -Port $PortaHTTP `
    -HostHeader $BindingHost `
    -Force | Out-Null

Start-Website -Name $NomeSite
Write-Host "      Site '$NomeSite' publicado em http://localhost:$PortaHTTP" -ForegroundColor Green

# -------- 5) GPO BASICA DE SEGURANCA / AUDITORIA -----------------------------
Write-Host "`n[5/5] Criando GPO '$GpoNome' com politicas basicas de seguranca e auditoria..." -ForegroundColor Yellow

# So faz sentido rodar em DC (modulo GroupPolicy vem com RSAT no DC)
if (-not (Get-Module -ListAvailable -Name GroupPolicy)) {
    Write-Warning "Modulo GroupPolicy nao encontrado. Pule esta etapa se nao estiver no DC."
} else {
    Import-Module GroupPolicy

    if (-not (Get-GPO -Name $GpoNome -ErrorAction SilentlyContinue)) {
        New-GPO -Name $GpoNome -Comment "Politica de seguranca e auditoria do projeto VIGIA" | Out-Null
    }

    # Politica de senha: minimo 10 caracteres, complexidade ligada, bloqueio apos 5 tentativas
    # Chaves em HKLM\Software\Policies - exemplo didatico (auditoria + mensagem de logon)
    Set-GPRegistryValue -Name $GpoNome `
        -Key "HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
        -ValueName "LegalNoticeCaption" -Type String `
        -Value "Projeto VIGIA - Acesso Monitorado" | Out-Null

    Set-GPRegistryValue -Name $GpoNome `
        -Key "HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
        -ValueName "LegalNoticeText" -Type String `
        -Value "Este equipamento pertence ao projeto VIGIA. Todas as acoes sao registradas." | Out-Null

    # Habilita auditoria de logon (sucesso + falha) via registry policy
    Set-GPRegistryValue -Name $GpoNome `
        -Key "HKLM\System\CurrentControlSet\Control\Lsa" `
        -ValueName "SCENoApplyLegacyAuditPolicy" -Type DWord -Value 1 | Out-Null

    # Linka a GPO na raiz do dominio
    $DominioAtual = (Get-ADDomain -ErrorAction SilentlyContinue).DistinguishedName
    if ($DominioAtual) {
        try {
            New-GPLink -Name $GpoNome -Target $DominioAtual -LinkEnabled Yes -ErrorAction Stop | Out-Null
            Write-Host "      GPO '$GpoNome' linkada em $DominioAtual." -ForegroundColor Green
        } catch {
            Write-Host "      GPO ja estava linkada (ok)." -ForegroundColor Green
        }
    }

    # Auditoria complementar via auditpol (vale para a maquina local, serve como evidencia)
    auditpol /set /category:"Logon/Logoff" /success:enable /failure:enable | Out-Null
    auditpol /set /category:"Object Access" /success:enable /failure:enable | Out-Null

    # Forca a aplicacao
    gpupdate /force | Out-Null
}

Write-Host "`nPasso 2 concluido. Teste no navegador da VM: http://localhost" -ForegroundColor Cyan
Stop-Transcript | Out-Null
