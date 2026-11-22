# Sistema Híbrido dArkOSen (Debian 13 Trixie) para Clones R36S-V20 / K36 (`RK3326-S` + RAM Xinyuwei 768 MB)

Este repositório documenta a engenharia reversa forense e contém os scripts automatizados, Device Trees (`DTS`/`DTB`) calibrados e overlays necessários para rodar o sistema moderno **dArkOSen (Debian GNU/Linux 13 "Trixie", `glibc 2.40`, SDL2/SDL3 atualizados)** em placas clones do portátil **R36S (revisão V20 / família K36)** equipadas com o processador **Rockchip RK3326-S** e módulo de memória RAM **Xinyuwei `XY6C256M32DM-H2` (768 MB físicos @ 328 MHz)**.

---

## 1. O Problema Original

Usuários das placas clones **R36S-V20 / K36** enfrentavam um impasse severo entre compatibilidade de hardware e atualização de software:

1. **Incompatibilidade com imagens oficiais recentes (Tela Preta / Travamento no Boot):**
   - Ao gravar imagens padrão do *ArkOS*, *dArkOS* ou *dArkOS4Clone* (baseadas no Kernel `4.4.189`), o console apresentava tela preta permanente ou congelava segundos após a inicialização.
2. **Obsolescência do sistema funcional de fábrica / ArkOS K36 (`Ubuntu 19.10 Eoan`):**
   - O único sistema que inicializava nessa revisão de placa utilizava o Kernel `5.10.160`, porém acoplado a um *rootfs* do **Ubuntu 19.10 (`glibc 2.30`)**, descontinuado em 2020.
   - Jogos modernos do **PortMaster** e motores recentes (compilados contra `glibc 2.34+` / `2.38+` e versões atuais de `libSDL2`/`libstdc++`) falhavam imediatamente ao iniciar por erro de símbolos da `glibc`.

---

## 2. Descobertas da Engenharia Reversa de Hardware

Através da inspeção forense dos registradores do SoC (`rockchip-otp0`), barramento de memória (`/proc/iomem`), blob de inicialização DDR (`idbloader`), desmontagem dos binários do Kernel (`Image`) e descompilação dos arquivos Device Tree (`rf3536k3ka.dtb` / `rf3536k4ka.dtb`), identificamos as características físicas reais desta placa:

### 2.1. Processador: Rockchip `RK3326-S` (Wafer `52 4b 33 26`, SoC ID `33260001`)
- Diferente do `RK3326` antigo (que opera até 1.5 GHz com `1.35V`), a variante **`RK3326-S` (`px30s`)** opera com teto seguro de **1296 MHz (`1296000 kHz`)** e tensão máxima de **`1.10V` (`1100000 uV`)** no regulador `vdd_arm`.
- Os DTBs genéricos de Kernel 4.4 injetavam `1.35V` nessa linha, causando instabilidade térmica e travamentos.

### 2.2. Memória RAM: Xinyuwei `XY6C256M32DM-H2` (768 MB reais @ 328 MHz)
- **Capacidade física real de 768 MB:** Embora a serigrafia `256M32` sugira 8 Gbit (1 GB), o inicializador de memória da Rockchip (`DDR V2.08 20220817` no `idbloader`) realiza a detecção geométrica automática das linhas/colunas (`bw col bk row cs dbw`) a cada boot e mapeia o barramento físico em **`0x00200000`–`0x2fffffff` (768 MB totais / ~717 MB utilizáveis pelo Linux após reservas de CMA e OP-TEE)**.
- **Adulteração descoberta no Kernel de fábrica (`pangjianwen@git` / `bruce@zed`):** Ao analisar o código de máquina da função `si_meminfo` e `meminfo_proc_show` no binário `Image` de fábrica, descobrimos que o fabricante chinês adulterou o kernel para **somar `+65.536 páginas` (`+256 MB` falsos)** quando a RAM é menor que 1 GB (exibindo **973 MB** falsos no RetroArch) ou multiplicar o valor por 2 (exibindo **1434 MB** falsos no `/proc/meminfo`). Isso fazia jogos do PortMaster tentarem alocar memória inexistente e sofrerem crash.
  - **Solução:** Substituímos o kernel adulterado de fábrica pelo binário `Image` limpo do **ArkOS K36 (`5.10.160-gc18be26ca0ba-dirty`, compilado por `lw@git`)**, que possui todos os drivers da placa mas reporta os **717 MB reais** sem falsificação.
- **Limite de Frequência DDR (328 MHz):** O chip Xinyuwei `XY6C256M32DM-H2` suporta apenas os pontos de operação de **194 MHz e 328 MHz**. Quando o controlador DMC (`rockchip-dmc`) ou scripts do sistema tentavam escalar para `450 MHz`, `528 MHz`, `666 MHz` ou `786 MHz`, o barramento DDR corrompia imediatamente.
  - **Solução:** No DTB calibrado (`rf3536k4ka_calibrated.dts`), todos os perfis `lpddr3-params` e `system-status-freq` foram travados em **`328 MHz` (`0x148` / `0x50140`)**, os nós `opp-450000000` e `opp-528000000` foram marcados como `status = "disabled"`, e o `/etc/dmc-settings.conf` do sistema foi fixado em `FREQ=328000000`.

### 2.3. Ausência de eMMC Físico e Numeração `/dev/mmcblk1`
- A placa **não possui chip eMMC nem SPI Flash** soldados, apenas o slot MicroSD.
- Contudo, o DTB do Kernel `5.10.160` mantém o controlador `dwmmc@ff390000` (`mmc0`) habilitado nas *aliases*, fazendo o kernel reservar o índice `0` e atribuir o cartão MicroSD principal (slot TF1) a **`/dev/mmcblk1`** (`mmcblk1p1 = BOOT`, `mmcblk1p2 = ROOTFS`, `mmcblk1p3 = EASYROMS`).

### 2.4. Controles Proprietários (`play_joystick` / `zed_joystick`)
- O Kernel `5.10.160` utiliza o driver específico `zed_joystick` que expõe o gamepad como **`play_joystick`** (GUID SDL2: `19000f6a706c61795f6a6f7973746900`), em vez do `GO-Super Gamepad` ou `singleadc-joypad` esperado pelo dArkOS original.

---

## 3. Arquitetura da Solução Híbrida

Em vez de tentar atualizar a `glibc` dentro do Ubuntu 19.10 antigo ou forçar o Kernel 4.4 a rodar na placa V20/K36, construímos uma **arquitetura híbrida** combinando a camada física do ArkOS K36 com o sistema operacional Debian 13 do dArkOSen:

| Camada | Origem | Função e Ajustes Aplicados |
|---|---|---|
| **Bootloader (primeiros 16 MB)** | ArkOS K36 (`bootloader_16M.bin`) | `idbloader` (`DDR V2.08 20220817 @ 333MHz`) + `U-Boot 2017.09` + `Trust BL31/BL32`. |
| **Partição 1 (`BOOT` - 500 MB FAT16)** | ArkOS K36 + Calibração V20 | Kernel limpo `5.10.160` (`lw@git`), `uInitrd`, DTB calibrado (`rf3536k4ka.dtb`), `logo.bmp` (`640x480` 24-bit com cabeçalho U-Boot) e ícones `battery_0..5.bmp` do dArkOSen. |
| **Partição 2 (`ROOTFS` - 9.5 GB ext4)** | dArkOSen (**Debian 13 Trixie**) | Convertido de `btrfs` para `ext4` (sem as flags `orphan_file` e `metadata_csum_seed` para total compatibilidade com o `e2fsck` do `uInitrd`), trazendo **`glibc 2.40`**, Python 3.13, SDL2 `2.32.10` e emuladores atualizados. |
| **Partição 3 (`EASYROMS` - ~19.1 GB exFAT)** | dArkOSen + Ferramentas K36 | Estrutura completa de ROMs, temas do EmulationStation, PortMaster e utilitários (`ZRam_Manager.sh`, `Diagnostico_Hardware_Real.sh`, `hp_autoswitch`). |

---

## 4. Todos os Problemas Resolvidos no Transplante (Passo a Passo Técnico)

Durante a integração do Debian 13 (dArkOSen) sobre o Kernel `5.10.160`, identificamos e corrigimos nos scripts 7 obstáculos críticos:

1. **Falha na montagem do `/roms` (`exFAT`) e Queda em `Emergency Mode`:**
   - **Causa:** O Kernel `5.10.160` do K36 não possui `CONFIG_EXFAT_FS` nativo e depende do `/usr/sbin/mount.exfat-fuse`. Porém, o binário `mount.exfat-fuse` exige a biblioteca `libfuse.so.2`, enquanto o Debian 13 Trixie vem apenas com a `libfuse3.so.4`. Ao falhar a montagem de `/roms` sem a flag `nofail` no `/etc/fstab`, o `systemd` abortava o boot gráfico e caía no shell de emergência (cursor `_` piscando na tela).
   - **Solução:** Transplantamos a `libfuse.so.2.9.9` (`aarch64-linux-gnu`) para o Debian 13, executamos `ldconfig` e adicionamos a opção `nofail` em `/boot` e `/roms` no `/etc/fstab`.
2. **Incompatibilidade de Versão do Driver da GPU Mali-G31 (`UK 10.6` vs `UK 11.38`):**
   - **Causa:** Em `/usr/lib/aarch64-linux-gnu` do ArkOS K36 existia um arquivo `libmali-bifrost-g31-rxp0-wayland-gbm.so` antigo (`r6p0`, interface **UK 10.6**). Quando o EmulationStation carregava esse arquivo contra o driver `/dev/mali0` do Kernel `5.10.160` (`g18p0`, interface **UK 11.38**), ocorria crash em loop com o erro:
     `file /dev/mali0 is not of a compatible version (user 10.6, kernel 11.38)`
   - **Solução:** Apontamos `libMali.so` (64-bit e 32-bit) para `libmali-bifrost-g31-rxp0-gbm.so` (`r13p0`, **UK 11.38**), que casa 100% com o driver `g18p0` do Kernel `5.10.160`.
3. **Mapeamento Completo do Gamepad (`play_joystick`) e Desinversão dos Botões A/B:**
   - **Causa:** O dArkOSen trazia `<bool name="InvertButtons" value="true" />` no `es_settings.cfg` e scripts que buscavam por `"GO-Super Gamepad"`.
   - **Solução:** Injetamos a assinatura `19000f6a706c61795f6a6f7973746900,play_joystick` no `es_input.cfg`, nos `gamecontrollerdb.txt` do sistema/PortMaster e nos `retroarch.cfg` (64-bit e 32-bit); alteramos `InvertButtons` e `menu_swap_ok_cancel_buttons` para `false` (`A` = Confirmar, `B` = Voltar); transplantamos o `buttonmon.sh`, o `ogage` e os daemons `*keydemon.py` do K36; e adaptamos o `fn_menu_watcher.sh` para escutar `KEY_FN`/`BTN_MODE` no `play_joystick`.
4. **Calibração do Áudio (`RK817 Codec`) e Eliminação de Distorção em 100%:**
   - **Causa:** Dois problemas combinados causavam áudio distorcido ("estourando") em 100% e inaudível abaixo de 50%:
     1. O ganho analógico `spk-volume` no DTB do K36 estava em `<0x0b>` (11), saturando o amplificador externo da placa V20 (enquanto os DTBs oficiais do dArkOS utilizam `<0x03>`).
     2. O `/var/local/asound.state` do dArkOS (`state.rockchiprk817co`, 5 controles) era incompatível com os 14 controles do driver `state.rockchiprk817` do Kernel `5.10.160`.
   - **Solução:** Reduzimos o ganho de hardware no DTB calibrado para **`spk-volume = <0x03>;`**, transplantamos o `/var/local/asound.state` original do K36 (`Playback Path = SPK`, `Playback Volume = 220/255`), ajustamos o `fixvolume.sh` e mantivemos o serviço `hp_autoswitch.service` para comutação automática entre alto-falante (`SPK`) e fone de ouvido (`HP`).
5. **Persistência de Data/Hora sem Bateria RTC e Fuso Horário (`UTC-3`):**
   - **Causa:** Como a placa não possui bateria de RTC e o fuso original apontava para `America/Regina` (Canadá), o relógio sempre voltava para a data de compilação da imagem (`11 de Novembro`).
   - **Solução:** Configuramos `/etc/localtime` para `America/Fortaleza` (`UTC-3`), incluímos a ferramenta visual `Change Time.sh` em **Options → System** e criamos o serviço `save-clock.service` (que salva o timestamp no shutdown em `/var/lib/systemd/timesync/clock` e restaura automaticamente no boot).
6. **Logos de Boot do U-Boot (`logo.bmp` e `battery_0..5.bmp`):**
   - **Causa:** O serviço `rotate-boot-logo.service` sorteava os 4 logos antigos do K36 dentro de `/boot/BMPs/` (`fireee.bmp`, `manila.bmp`, `purple.bmp`, `logo.bmp`) e sobrescrevia o `/boot/logo.bmp`. Além disso, o leitor BMP do U-Boot do K36 rejeita arquivos BMP cujo campo `biSizeImage` no cabeçalho de 54 bytes não esteja zerado.
   - **Solução:** Limpamos `/boot/BMPs/`, redimensionamos o logo oficial do dArkOSen para `640x480` 24-bit clonando os 54 bytes exatos do cabeçalho U-Boot do K36, e geramos os 7 ícones `battery_0..5.bmp` / `battery_fail.bmp` (`220x110`, `72656 bytes`) no tema escuro/neon do dArkOSen.
7. **Otimização de Espaço em Disco (`ROOTFS` de 9.5 GB + `EASYROMS` de 19.1 GB + ZRam 512 MB `lz4`):**
   - Removemos arquivos temporários duplicados do firstboot (`/tempthemes` = 276 MB) e dimensionamos a partição `ROOTFS` para **9,5 GB** (~2 GB livres no sistema), liberando **19,1 GB** na partição `EASYROMS` em um cartão de 32 GB.
   - Configuramos **512 MB de Swap ZRam com algoritmo `lz4`**, essencial para rodar Ports pesados dentro dos 717 MB de RAM física.

---

## 5. Estrutura dos Arquivos deste Repositório

- [`montar_e_gravar_hibrido.sh`](montar_e_gravar_hibrido.sh): Script principal que particiona o cartão SD do zero (GPT: `500M BOOT` + `9.5G ROOTFS ext4` + `Restante EASYROMS exFAT`), grava o bootloader e o kernel limpo do K36, extrai o Debian 13 do dArkOSen e injeta todos os drivers, DTBs e configurações.
- [`corrigir_cartao.sh`](corrigir_cartao.sh): Script rápido (~5 segundos) para atualizar um cartão já gravado com o Kernel limpo (`717 MB`), DTB com áudio calibrado (`spk-volume = 0x03`), desinversão dos botões A/B, logos de boot/bateria do dArkOSen e persistência do relógio `UTC-3`.
- [`redimensionar_rootfs_9_5gb.sh`](redimensionar_rootfs_9_5gb.sh): Utilitário que encolhe a partição `ROOTFS` de 12 GB para 9,5 GB em um cartão já gravado e expande a partição `EASYROMS` para ~19,1 GB sem perder nenhum arquivo.
- [`rf3536k4ka_calibrated.dts`](rf3536k4ka_calibrated.dts), [`rf3536k4ka.dtb`](rf3536k4ka.dtb) e [`rf3536k3ka.dtb`](rf3536k3ka.dtb): Código-fonte Device Tree e binários compilados com RAM travada em 328 MHz, curva de bateria de 2808 mAh e ganho de áudio `spk-volume = <0x03>`.
- [`prepare_k36_overlay.py`](prepare_k36_overlay.py): Script Python que automatiza a calibração do DTS e a extração dos módulos e binários da imagem original do ArkOS K36.
- [`Diagnostico_Hardware_Real.sh`](Diagnostico_Hardware_Real.sh): Ferramenta forense para coletar dados reais do silício (`OTP/eFuse`, `MIDR_EL1`, reguladores PMIC `RK817`, clocks do DMC, GPU Mali, I2C e painel DRM).
- [`rootfs_overlay/`](rootfs_overlay/): Módulos do Kernel `5.10.160`, `libfuse.so.2.9.9`, `mount.exfat-fuse`, `asound.state.k36`, `hp_autoswitch.sh`, `es_input.cfg` e configurações de controles do K36.
- [`darkosen_logo_640x480.bmp`](darkosen_logo_640x480.bmp) e [`battery_bmps/`](battery_bmps/): Logos de inicialização e animação de recarga da bateria com cabeçalho compatível com o U-Boot do K36.

---

## 6. Como Utilizar

### Opção A: Criar o cartão SD híbrido do zero
Com a imagem `dArkOSen_R36_11112026.img` (e os dumps `bootloader_16M.bin`, `boot_500M.fat`, `Image_arkos_k36` e `uInitrd_arkos_k36` do ArkOS K36) na pasta do projeto, insira o cartão MicroSD (ex.: `/dev/sda`) e execute:

```bash
sudo ./montar_e_gravar_hibrido.sh /dev/sda
sudo ./corrigir_cartao.sh /dev/sda
```

### Opção B: Aplicar as correções mais recentes em um cartão já gravado
```bash
sudo ./corrigir_cartao.sh /dev/sda
```

### Opção C: Redimensionar um cartão de 12 GB ROOTFS para 9.5 GB ROOTFS (+2.5 GB para jogos)
```bash
sudo ./redimensionar_rootfs_9_5gb.sh /dev/sda
```
