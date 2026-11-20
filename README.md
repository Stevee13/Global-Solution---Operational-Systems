# VIGIA / Fire Intelligence — Infraestrutura Windows Server (Operating Systems)

> **Global Solution CitizenTech — FIAP 2026.2**
> Disciplina: **Operating Systems (Windows Server)**
> Entrega: repositório com os scripts PowerShell que automatizam a infraestrutura
> da CitizenTech **VIGIA / Fire Intelligence** dentro de uma VM Windows Server.

---

## Vídeo de demonstração

**Link da apresentação em vídeo:** `<COLAR AQUI O LINK DO YOUTUBE/DRIVE>`

> O vídeo mostra, na VM Windows Server, a execução dos 4 scripts, o site publicado
> no IIS, a simulação da falha do `VigiaAppPool` com recuperação automática e a
> abertura do Performance Monitor com o Data Collector Set de alertas.

---

## Ficha da CitizenTech

| Campo | Descrição |
|---|---|
| **Nome da CitizenTech** | VIGIA / Fire Intelligence |
| **Território** | Cavalcante — GO (Bioma Cerrado) |
| **Cidadão beneficiado** | Produtores rurais, moradores e grupos sensíveis à fumaça, brigadistas |
| **Problema** | Incêndios florestais e queimadas sem aviso prévio afetando saúde, produção rural e áreas de conservação |
| **Como funciona** | Plataforma de diagnóstico territorial integrando INPE, MapBiomas, INMET e ICMBio; triagem de queimada prescrita × queimada ilegal; aviso comunitário em tempo real; operação offline para brigadistas em campo |
| **Indicadores de impacto** | Redução de queimadas não comunicadas, proteção preventiva de grupos vulneráveis à fumaça, redução do tempo de resposta em campo |
| **ODS conectados** | **ODS 2** (Agricultura Sustentável) · **ODS 3** (Saúde e Bem-Estar) · **ODS 11** (Cidades e Comunidades Sustentáveis) · **ODS 13** (Ação Contra a Mudança Global do Clima) |

---

## Arquitetura da Infraestrutura Windows Server

A VM Windows Server foi preparada em 4 camadas, cada uma automatizada por um
script PowerShell deste repositório. O diagrama lógico é:

```
      ┌─────────────────────────────────────────────────────────────┐
      │        VM Windows Server  (SRV-VIGIA  ·  vigia.local)       │
      │                                                             │
      │  [1] Rede + Identidade        [2] Hospedagem Web (IIS)      │
      │      IP fixo                      Site VigiaWeb             │
      │      AD DS                        AppPool VigiaAppPool      │
      │      DNS vigia.local              NTFS restrito             │
      │                                                             │
      │  [3] Políticas (GPO) +        [4] Monitoramento +           │
      │      Auditoria                    Tolerância a Falhas       │
      │      banner legal                 PerfMon (CPU/RAM/Disco)   │
      │      logon success/fail           Recovery W3SVC + Pool     │
      └─────────────────────────────────────────────────────────────┘
```

### 1. Rede e Identidade
- **IP estático** configurado na interface da VM via `New-NetIPAddress`.
- **Hostname** padronizado como `SRV-VIGIA`.
- **Active Directory Domain Services (AD DS)** instalado e promovido via
  `Install-ADDSForest`, criando a floresta e o domínio local **`vigia.local`**.
- **DNS** instalado junto do AD DS, autoritativo para `vigia.local` e usado
  pelo próprio servidor (loopback `127.0.0.1`).

### 2. Hospedagem Web no IIS
- Instalação de **IIS (Web-Server)** + **Web-Mgmt-Tools** e importação do
  módulo `WebAdministration`.
- Criação do **Application Pool `VigiaAppPool`** (identidade
  *ApplicationPoolIdentity*, .NET v4.0, `AlwaysRunning`) — isolado do pool
  padrão para não comprometer outros serviços em caso de falha.
- Publicação do **Site `VigiaWeb`** apontando para `C:\inetpub\vigia`, com
  um `index.html` de teste já populado.
- **NTFS endurecido** em `C:\inetpub\vigia`: herança quebrada e *somente* as
  identidades `SYSTEM`, `BUILTIN\Administrators` e `BUILTIN\IIS_IUSRS` com
  permissão (as duas primeiras com *FullControl*; o grupo do IIS apenas com
  *ReadAndExecute*). Grupos amplos como *Users* / *Authenticated Users* são
  removidos.

### 3. Políticas de Grupo (GPO) e Auditoria
- Criação da GPO **`GPO_VIGIA_Seguranca`** linkada à raiz do domínio
  `vigia.local`.
- Banner legal de logon (`LegalNoticeCaption` + `LegalNoticeText`) alertando
  que o acesso é monitorado.
- Auditoria via `auditpol` ativada para as categorias **Logon/Logoff**
  (sucesso + falha) e **Object Access** (sucesso + falha), gerando evidência
  no Event Viewer sempre que houver tentativa de acesso.
- `gpupdate /force` ao final para aplicação imediata.

### 4. Monitoramento de Recursos
- Criação do **Data Collector Set `VIGIA_Alertas`** via `logman create alert`,
  com três *thresholds* simultâneos:
  - `\Processor(_Total)\% Processor Time > 85`
  - `\Memory\Available MBytes < 500`
  - `\LogicalDisk(C:)\% Free Space < 10`
- Intervalo de amostragem de **15 s** e registro no **Event Log** sempre que
  um gatilho é cruzado — visível em *Performance Monitor → Data Collector
  Sets → User Defined → VIGIA_Alertas*.

### 5. Tolerância a Falhas e Continuidade
- **Serviço W3SVC** configurado via `sc.exe failure` para **reiniciar
  automaticamente** nas falhas (`reset 86400`, ações `restart/5s/10s/15s`).
- **`VigiaAppPool`** com **Rapid-Fail Protection desligado** e `startMode`
  **`AlwaysRunning`**, garantindo que o pool sempre volte após uma queda.
- **Reinício preventivo** do pool a cada 1 hora para liberar memória.
- Funções `Invoke-VigiaFalhaServico` e `Invoke-VigiaFalhaAppPool` prontas
  para **simular a falha** (kill no serviço / no `w3wp.exe`) e comprovar o
  retorno automático.

---

## Guia de Execução dos Scripts

> **Pré-requisitos:** VM com **Windows Server 2019/2022**, acesso de
> **Administrador local**, placa de rede em bridge ou host-only com IP
> planejado, e snapshot da VM antes de começar.

Abra o **PowerShell como Administrador** dentro da VM e rode na ordem:

### Passo 1 — Rede, AD DS e DNS
```powershell
cd C:\caminho\do\projeto\scripts
.\01_rede_ad_dns.ps1
```
Ajuste no topo do script, se necessário: `$NomeInterface`, `$IPFixo`,
`$GatewayPadrao`. Ao final da promoção do domínio **a VM reinicia sozinha**.
Faça login novamente como **`VIGIA\Administrator`** antes de seguir.

### Passo 2 — IIS, NTFS e GPO
```powershell
.\02_iis_ntfs_gpo.ps1
```
Depois de rodar, abra o navegador da VM em **`http://localhost`** e confirme
a página do VIGIA. Confirme também no `inetmgr` que existe o site **VigiaWeb**
usando o **VigiaAppPool**.

### Passo 3 — Tolerância a Falhas
```powershell
.\03_tolerancia_falha.ps1

# Simular queda do serviço IIS (deve voltar sozinho em ~5s):
Invoke-VigiaFalhaServico

# Simular queda do w3wp.exe do pool (outro é criado imediatamente):
Invoke-VigiaFalhaAppPool
```
Tire **print do antes e depois** para anexar nas evidências.

### Passo 4 — Monitoramento + Evidências
```powershell
.\04_monitoramento_evidencias.ps1
```
Gera dois artefatos:
- O Data Collector Set **`VIGIA_Alertas`** no Performance Monitor.
- O arquivo **`C:\VIGIA\evidencias\evidencias_rede.txt`** com toda a saída
  de rede que deve ser copiada para a pasta [`evidencias/`](evidencias/)
  deste repositório.

> Todos os scripts gravam *transcript* completo em `C:\VIGIA\logs\` — esses
> `.log` também são evidência válida da execução.

---

## Comandos de Verificação e Evidências

Os três comandos abaixo são executados automaticamente pelo script 04 e
gravados em `evidencias_rede.txt`. Eles comprovam que as camadas de rede,
nome e conectividade estão funcionais.

### `ipconfig /all`
Lista **todas as interfaces** de rede com IP, máscara, gateway, servidores
DNS e sufixo DNS do domínio. É a evidência de que:
- o **IP fixo** configurado no passo 1 está aplicado;
- o **DNS primário** aponta para o próprio servidor (`127.0.0.1`);
- o **sufixo DNS** é `vigia.local`.

Trecho esperado:
```
Ethernet adapter Ethernet:
   Connection-specific DNS Suffix  . : vigia.local
   IPv4 Address. . . . . . . . . . . : 192.168.56.10(Preferred)
   Subnet Mask . . . . . . . . . . . : 255.255.255.0
   Default Gateway . . . . . . . . . : 192.168.56.1
   DNS Servers . . . . . . . . . . . : 127.0.0.1
```

### `nslookup vigia.local`
Consulta o servidor DNS para o nome do domínio e devolve o IP do próprio
Controlador de Domínio. Comprova que o **AD DS + DNS** estão respondendo
pela zona `vigia.local`.

Trecho esperado:
```
Server:  SRV-VIGIA.vigia.local
Address: 127.0.0.1

Name:    vigia.local
Address: 192.168.56.10
```

### `Test-NetConnection`
`Test-NetConnection` substitui o antigo `ping` com informações extras —
roteamento, latência, porta aberta/fechada. O script 04 roda duas variantes:
- `Test-NetConnection 8.8.8.8` → prova que a VM **tem saída para a Internet**.
- `Test-NetConnection vigia.local -Port 80` → prova que o **IIS está
  escutando** na porta 80 e que o DNS resolve o host corretamente.

Trecho esperado:
```
ComputerName     : vigia.local
RemoteAddress    : 192.168.56.10
RemotePort       : 80
InterfaceAlias   : Ethernet
TcpTestSucceeded : True
```

### Estrutura da pasta `evidencias/`

Toda evidência para o relatório fica em [`evidencias/`](evidencias/):

```
evidencias/
├── evidencias_rede.txt           # saída dos 3 comandos acima (gerada pelo script 04)
├── print_01_iis_site.png         # IIS Manager mostrando VigiaWeb + VigiaAppPool
├── print_02_ntfs_acl.png         # Propriedades → Segurança da pasta C:\inetpub\vigia
├── print_03_gpo.png              # Group Policy Management com a GPO_VIGIA_Seguranca
├── print_04_perfmon.png          # Data Collector Set VIGIA_Alertas rodando
├── print_05_falha_antes.png      # VigiaAppPool antes da simulação de falha
└── print_06_falha_depois.png     # Pool reiniciado automaticamente após o kill
```

---

## Estrutura do repositório

```
GS - CitizenTech/
├── README.md                     # este arquivo
├── scripts/
│   ├── 01_rede_ad_dns.ps1        # IP fixo + hostname + AD DS + DNS
│   ├── 02_iis_ntfs_gpo.ps1       # IIS + NTFS restrito + Site/AppPool + GPO
│   ├── 03_tolerancia_falha.ps1   # Recovery W3SVC + VigiaAppPool + simuladores
│   └── 04_monitoramento_evidencias.ps1  # PerfMon DCS + evidências de rede
└── evidencias/
    └── .gitkeep                  # prints e arquivos de evidência vão aqui
```

---

## Critérios de avaliação cobertos

| Critério da disciplina | Script | Como é atendido |
|---|---|---|
| Configuração de rede e identidade | [01_rede_ad_dns.ps1](scripts/01_rede_ad_dns.ps1) | IP fixo, hostname, AD DS e DNS `vigia.local` |
| Servidor Web (IIS) | [02_iis_ntfs_gpo.ps1](scripts/02_iis_ntfs_gpo.ps1) | Site `VigiaWeb` + Pool `VigiaAppPool` dedicado |
| Permissões NTFS | [02_iis_ntfs_gpo.ps1](scripts/02_iis_ntfs_gpo.ps1) | Herança quebrada; só SYSTEM + Admins + IIS_IUSRS |
| GPO e auditoria | [02_iis_ntfs_gpo.ps1](scripts/02_iis_ntfs_gpo.ps1) | `GPO_VIGIA_Seguranca` + `auditpol` em logon/objeto |
| Tolerância a falhas | [03_tolerancia_falha.ps1](scripts/03_tolerancia_falha.ps1) | `sc.exe failure` + Rapid-Fail OFF + `AlwaysRunning` |
| Monitoramento | [04_monitoramento_evidencias.ps1](scripts/04_monitoramento_evidencias.ps1) | DCS `VIGIA_Alertas` com CPU/RAM/Disco |
| Evidências de rede | [04_monitoramento_evidencias.ps1](scripts/04_monitoramento_evidencias.ps1) | `evidencias_rede.txt` com os 3 comandos |

---

**Entrega:** GS CitizenTech — FIAP 2026.2 · Projeto **VIGIA / Fire Intelligence** · Disciplina **Operating Systems**.
