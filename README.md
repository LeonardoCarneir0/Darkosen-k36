# dArkOSen Hybrid (Debian 13 Trixie + Kernel 5.10.160) para R36S-V20 2025-05-18 (Lote 2549) / K36

Solução híbrida, scripts automatizados e Device Tree (`DTS`/`DTB`) calibrado para rodar o **dArkOSen (Debian GNU/Linux 13 "Trixie", `glibc 2.41`, SDL2 `2.32.10`)** em placas clones **R36S-V20 `2025-05-18` (lote `2549`) / família K36** equipadas com processador **Rockchip RK3326-S** e módulo de RAM **Xinyuwei `XY6C256M32DM-H2` (768 MB físicos @ 328 MHz)**.

---

## Por que este projeto existe?

Quem tem essa revisão específica de clone (**R36S-V20 `2025-05-18` lote `2549`**) ficava preso entre dois extremos:

- **Sistemas novos (dArkOSen, ArkOS, dArkOS4Clone com Kernel `4.4.189`):** Não dão boot (tela preta ou travamento imediato), mesmo usando o DTB beta da placa V20 `2025-05-18`.
- **Sistema funcional (ArkOS K36 / fábrica com Kernel `5.10.160`):** Dá boot normalmente, mas usa um *rootfs* do **Ubuntu 19.10 (`glibc 2.30`)**, descontinuado em 2020 — impedindo a execução de quase todos os jogos recentes do **PortMaster**.

**A solução:** Manter a camada física que funciona nesta placa (**Bootloader `DDR V2.08 @ 333 MHz` + Kernel `5.10.160` limpo + DTB calibrado**) e rodar por cima o **sistema operacional completo Debian 13 (`glibc 2.41`) do dArkOSen** em `ext4`.

---

## Raio-X Forense do Hardware (`R36S-V20 2025-05-18 2549`)

Dados coletados diretamente do hardware (`rockchip-otp0`, `MIDR_EL1`, `/proc/iomem`, `idbloader` e `dmesg`):

| Componente | Especificação Real Detectada | Impacto no Sistema |
|---|---|---|
| **SoC / CPU** | **Rockchip `RK3326-S`** (4× Cortex-A35, OTP `52 4b 33 26`, SoC ID `33260001`) | Teto seguro de **1296 MHz @ `1.10V`** (`vdd_arm`). DTBs de Kernel 4.4 tentavam aplicar `1.35V` / `1.5 GHz`. |
| **GPU** | **ARM Mali-G31 MP1 r0p0** (`0x7093`, até `520 MHz`) | Driver do Kernel `5.10.160` é `g18p0` (**UK 11.38**); exige `libMali.so` compatível (`r13p0` / UK 11.38). |
| **Memória RAM** | **Xinyuwei `XY6C256M32DM-H2`** — **768 MB físicos reais** (`0x00200000`–`0x2fffffff`, ~717 MB utilizáveis) | Opera de forma estável apenas em **194 MHz e 328 MHz**. Escalar para `450/528/666/786 MHz` trava o console. |
| **Armazenamento** | **Sem eMMC e sem SPI Flash** (apenas MicroSD) | Como o DTB do Kernel `5.10` mantém o nó `mmc0` reservado, o slot TF1 é mapeado em **`/dev/mmcblk1`**. |
| **PMIC / Áudio** | **Rockchip `RK817`** (chip ID `0x8170` via I2C `0-0020`) | Amplificador externo satura com `spk-volume = <0x0b>`. Calibrado para **`spk-volume = <0x03>`**. |
| **Controles** | Driver proprietário **`zed_joystick`** → **`play_joystick`** | GUID SDL2 `19000f6a706c61795f6a6f7973746900` (diferente do `GO-Super Gamepad` esperado pelo dArkOS). |
| **Tela** | Painel MIPI-DSI **`640×480 @ 59 Hz`** (4 lanes) | Sequência DSI compatível com `rf3536k4ka.dtb` / `rf3536k3ka.dtb`. |

### Por que os DTBs beta da `V20 2025-05-18` no dArkOS não funcionam nesta placa?
1. **Bootloader incompatível:** O `idbloader` da imagem padrão do dArkOS (MBR) não inicializa a RAM Xinyuwei de 768 MB a `333 MHz` — a placa trava antes mesmo de carregar o kernel ou o DTB.
2. **Frequência de RAM acima de 328 MHz:** Os DTBs beta da V20 foram feitos para unidades com 1 GB de RAM a `528/666 MHz`, enquanto o lote `2549` com Xinyuwei 768 MB congela acima de `328 MHz`.
3. **Diferença de Kernel (`4.4.189` vs `5.10.160`) e Particionamento:** O dArkOS espera `root=/dev/mmcblk0p2` em `btrfs` e controles `GO-Super Gamepad`, enquanto esta revisão usa `mmcblk1p2` em `ext4` e `play_joystick`.

### Descoberta sobre o Kernel de fábrica ("RAM falsa")
Na análise do binário `Image` de fábrica (`5.10.160`, compilado por `pangjianwen@git` / `bruce@zed`), verificamos que o fabricante adulterou o reporte de memória (`si_meminfo` / `/proc/meminfo`) para somar **`+256 MB` falsos** (mostrando **973 MB** no RetroArch) ou dobrar a leitura (mostrando **~1,4 GB**), fazendo jogos do PortMaster sofrerem crash ao tentar alocar memória inexistente.
- **Correção:** Utilizamos o kernel **`5.10.160-gc18be26ca0ba-dirty` limpo do ArkOS K36 (`lw@git`)**, que mantém todos os drivers do hardware e reporta fielmente os **~717 MB reais** + **512 MB de Swap ZRam (`lz4`)**.

---

## O que a Solução Híbrida Corrige e Entrega

1. **Debian 13 Trixie (`glibc 2.41`) sobre Kernel `5.10.160` limpo:**
   - Partição `ROOTFS` convertida de `btrfs` para `ext4` (sem as flags `orphan_file` e `metadata_csum_seed` para compatibilidade total com o `e2fsck` do `uInitrd`).
   - Módulos do Kernel `5.10.160` transplantados para `/usr/lib/modules/` com symlinks para todas as variantes do kernel.
2. **Montagem de `/roms` (`exFAT`) sem cair em `Emergency Mode`:**
   - Transplante da biblioteca `libfuse.so.2.9.9` (`aarch64-linux-gnu`) necessária para o `mount.exfat-fuse` rodar no Debian 13 (que traz apenas `libfuse3.so.4`), somado à opção `nofail` no `/etc/fstab`.
3. **Aceleração Gráfica Mali-G31 (`UK 11.38`):**
   - Alinhamento dos links `libMali.so` (64-bit e 32-bit) para `libmali-bifrost-g31-rxp0-gbm.so` (`r13p0`, **UK 11.38**), eliminando o crash `file /dev/mali0 is not of a compatible version (user 10.6, kernel 11.38)`.
4. **Trava Segura de RAM (`328 MHz`) + ZRam `512 MB` (`lz4`):**
   - DTB calibrado (`rf3536k4ka_calibrated.dts`) desativando `opp-450000000` e `opp-528000000` e fixando `lpddr3-params` / `system-status-freq` em `328 MHz`, junto com `/etc/dmc-settings.conf` em `FREQ=328000000`.
   - Swap ZRam de **512 MB com compressão `lz4`** ativo no boot para suportar Ports pesados nos 717 MB físicos.
5. **Controles (`play_joystick`), Botões A/B e Atalhos:**
   - Mapeamento do `play_joystick` aplicado no EmulationStation (`es_input.cfg`), RetroArch 64/32-bit, `gamecontrollerdb.txt` do sistema e PortMaster, `buttonmon.sh`, `ogage` e `fn_menu_watcher.sh`.
   - Botões A e B desinvertidos (`InvertButtons = false` e `menu_swap_ok_cancel_buttons = "false"` → `A` confirma, `B` volta).
6. **Áudio Calibrado (`RK817`) sem Distorção em 100%:**
   - Ganho de hardware do alto-falante reduzido no DTB para **`spk-volume = <0x03>;`** (mesmo padrão dos DTBs oficiais do dArkOS).
   - Transplante do `/var/local/asound.state` real do K36 (`state.rockchiprk817`, `Playback Path = SPK`, `Playback Volume = 220/255`) + serviço `hp_autoswitch.service` para troca automática entre alto-falante e fone de ouvido.
7. **Relógio sem RTC (`UTC-3`), Logos do dArkOSen e Particionamento Otimizado:**
   - Fuso horário `America/Fortaleza` (`UTC-3`), serviço `save-clock.service` (salva a hora no desligamento e restaura no boot) e utilitário `Change Time.sh` em **Options → System**.
   - Logo de boot do **dArkOSen** em `640×480` 24-bit com cabeçalho BMP exato do U-Boot do K36 + novos ícones `battery_0..5.bmp` / `battery_fail.bmp` (`220×110`).
   - Particionamento otimizado para cartão de 32 GB: **`500 MB BOOT`** + **`9.5 GB ROOTFS`** (~2 GB livres no sistema) + **`~19.1 GB EASYROMS`** (`exFAT`).

---

## Estrutura do Repositório

| Arquivo / Pasta | Descrição |
|---|---|
| `montar_e_gravar_hibrido.sh` | Constrói e grava o cartão SD híbrido do zero (GPT: `BOOT` + `ROOTFS ext4` + `EASYROMS exFAT`). |
| `corrigir_cartao.sh` | Aplica de forma rápida (~5s) o kernel limpo, DTB com áudio `0x03`, desinversão A/B, logos do dArkOSen e relógio `UTC-3` em um cartão já gravado. |
| `redimensionar_rootfs_9_5gb.sh` | Encolhe o `ROOTFS` de 12 GB para 9,5 GB e expande o `EASYROMS` para ~19,1 GB preservando todos os arquivos. |
| `rf3536k4ka_calibrated.dts` / `.dtb` | Código-fonte DTS e binários compilados (`rf3536k4ka.dtb`, `rf3536k3ka.dtb`) calibrados para `RK3326-S` + Xinyuwei `328 MHz` + `spk-volume = 0x03`. |
| `prepare_k36_overlay.py` | Script Python de extração dos módulos e binários do ArkOS K36 e compilação do DTB calibrado. |
| `Diagnostico_Hardware_Real.sh` | Script forense para inspecionar OTP/eFuse, CPU, GPU, reguladores, DMC, I2C e painel DRM direto no portátil. |
| `rootfs_overlay/` | Módulos do Kernel `5.10.160`, `libfuse.so.2.9.9`, `mount.exfat-fuse`, `asound.state.k36`, `hp_autoswitch.sh`, `es_input.cfg` e configs de controles. |
| `darkosen_logo_640x480.bmp` e `battery_bmps/` | Logo de boot e ícones de bateria recarregando compatíveis com o U-Boot do K36. |

---

## Como Usar

> **Aviso:** Os scripts contêm trava de segurança contra gravação em discos NVMe/não-removíveis, mas sempre confirme o dispositivo correto do seu leitor SD com `lsblk` (ex.: `/dev/sda`). **Não execute atualizações OTA do dArkOSen que sobrescrevam `/boot`**, pois elas substituem o Kernel `5.10.160` pelo `4.4.189`.

### 1. Pré-requisitos (arquivos grandes ignorados no `.gitignore`)
Coloque na raiz desta pasta:
- `dArkOSen_R36_11112026.img` (imagem oficial do dArkOSen descompactada)
- `bootloader_16M.bin`, `boot_500M.fat`, `Image_arkos_k36` e `uInitrd_arkos_k36` (extraídos da imagem `ArkOS_K36_v2.0_08112025.img`)

### 2. Gravar um cartão SD do zero
```bash
sudo ./montar_e_gravar_hibrido.sh /dev/sda
sudo ./corrigir_cartao.sh /dev/sda
```

### 3. Aplicar apenas os patches mais recentes em um cartão já gravado
```bash
sudo ./corrigir_cartao.sh /dev/sda
```

### 4. Redimensionar um cartão de 12 GB `ROOTFS` para 9.5 GB `ROOTFS` (+2.5 GB no `EASYROMS`)
```bash
sudo ./redimensionar_rootfs_9_5gb.sh /dev/sda
```
