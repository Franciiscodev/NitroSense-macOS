# Porting Guide — Adapting NitroSense-macOS to Other Acer Nitro 5 Models

*(Guia em Português disponível na [segunda metade deste documento](#guia-de-portabilidade-português-br))*

---

## Overview (English)

`NitroSense-macOS` controls the laptop's Embedded Controller (EC) and Acer Gaming WMI interface through an ACPI companion device (`\_SB.NTRO` with `_HID` `NTRO0001` in `ACPI/SSDT-NITRO.dsl`) matched by `NitroEC.kext`.

Although most Intel-based **Acer Nitro 5 (`AN515-51` through `AN515-57`)** laptops share the same Compal/Insyde EC firmware layout for fan control, **two things change across generations**:
1. **ACPI Root PCI / EC Device Paths** (`\_SB.PCI0` on 7th–9th Gen vs `\_SB.PC00` on 11th+ Gen)
2. **EC RAM Memory-Mapped I/O (MMIO) Base Address** (`0xFC7E0800` on AN515-52 vs `0xFE0B0800` on AN515-57)
3. **Minor EC Register & WMI Differences** (e.g., CoolBoost at `0x10` vs WMI, temperature sensor offsets, 4-zone RGB support)

This guide walks you through porting `NitroSense-macOS` to your specific Acer Nitro 5 model using your dumped ACPI tables (`DSDT.aml` / `SSDT*.aml`) and [nbfc-linux](https://github.com/nbfc-linux/nbfc-linux) configurations.

---

### Step 1: Dump and Disassemble Your ACPI Tables

1. Dump your raw ACPI tables (`DSDT.aml` and `SSDT*.aml`) using:
   - **OpenCore Debug** (`Misc -> Debug -> SysReport = True`, which saves tables to `EFI/OC/SysReport/ACPI/`), or
   - **SSDTTime** (on Windows/Linux), or `acpidump` on Linux.
2. Disassemble `DSDT.aml` and all `SSDT*.aml` files using `iasl`:
   ```bash
   iasl -d DSDT.aml SSDT*.aml
   ```

---

### Step 2: Find Your ACPI Paths and EC MMIO Address in `DSDT.dsl`

Open `DSDT.dsl` and search for `PNP0C09` (the Embedded Controller device):

```bash
grep -n -C 35 "PNP0C09" DSDT.dsl
```

Look for two critical pieces of information right under `Device (EC0)` (or `EC`):

1. **The Parent Scope**:
   - On 7th/8th/9th Gen Intel (`AN515-51`, `AN515-52`, `AN515-53`, `AN515-54`):
     `\_SB.PCI0.LPCB.EC0`, `\_SB.PCI0.LPCB.PS2K`, `\_SB.PCI0.WMID`
   - On 10th/11th+ Gen Intel (`AN515-57`, etc.):
     `\_SB.PC00.LPCB.EC0`, `\_SB.PC00.LPCB.PS2K`, `\_SB.PC00.WMID`

   You can also verify live on macOS without rebooting:
   ```bash
   ioreg -p IOACPIPlane -w0 | grep -E "PCI0|PC00|LPCB|EC0|PS2K|WMID"
   ```

2. **The `SystemMemory` OperationRegion (`ECMM`) Base Address**:
   Right below `Method (_REG)` inside `Device (EC0)`, look for:
   ```asl
   OperationRegion (ECMM, SystemMemory, 0xFC7E0800, 0x1000)
   Field (ECMM, AnyAcc, Lock, Preserve)
   ```
   - On `AN515-52`: `0xFC7E0800`
   - On `AN515-57`: `0xFE0B0800`

   > **Warning**: Never use another model's `SystemMemory` address blindly. Reading/writing the wrong physical MMIO address can hang the system or corrupt hardware state.

---

### Step 3: Verify Your EC Register Map (`DSDT.dsl` + `nbfc-linux`)

1. **Check `Field (ECMM, ...)` in `DSDT.dsl`** (and `GGSI` inside the Acer WMI `SSDT` table if present):
   Look up the byte offsets of the EC fields in your `DSDT.dsl`:
   ```asl
   Offset (0x13),
   C1FR,   16,     // CPU Fan 1 RPM (16-bit LE)
   G1FR,   16,     // GPU Fan 1 RPM (16-bit LE)
   ...
   Offset (0x2A),
   S1TV,   8,      // System Temperature
   ...
   Offset (0xB0),
   CTMP,   8,      // CPU Temperature (°C)
   CTML,   8,
   EST3,   8,
   SKTB,   8,      // Socket / System Temperature (0xB3)
   SKTC,   8,      // dGPU Temperature (0xB4)
   ```

2. **Cross-reference with `nbfc-linux`**:
   Check [`share/nbfc/configs/`](https://github.com/nbfc-linux/nbfc-linux/tree/main/share/nbfc/configs) in `nbfc-linux` for your model (or the closest sibling model, e.g. `Acer Nitro AN515-51.json`, `AN515-54.json`, `AN515-57.json`):
   - **CPU Fan**:
     - `ReadRegister`: `19` (`0x13`)
     - `WriteRegister`: `55` (`0x37`) — manual speed percentage (`0..100`)
     - Mode register: `34` (`0x22`) — `4` (`0x04`) = Auto, `8` (`0x08`) = Max, `12` (`0x0C`) = Manual
   - **GPU Fan**:
     - `ReadRegister`: `21` (`0x15`)
     - `WriteRegister`: `58` (`0x3A`) — manual speed percentage (`0..100`)
     - Mode register: `33` (`0x21`) — `16` (`0x10`) = Auto, `32` (`0x20`) = Max, `48` (`0x30`) = Manual
   - **CoolBoost**:
     - Register `16` (`0x10`) — `1` (`0x01`) = On, `0` (`0x00`) = Off

---

### Step 4: Update the Source Files

1. **`ACPI/SSDT-NITRO.dsl`**:
   - Update `External (...)` and `Scope (...)` paths (`_SB.PCI0` vs `_SB.PC00`).
   - Update `OperationRegion (ERDM, SystemMemory, 0x..., 0x0100)` and `OperationRegion (EWB1, SystemMemory, (0x... + Arg0), One)` with your `ECMM` physical base address from Step 2.
2. **`Kext/NitroEC.cpp`**:
   - Ensure `isWriteAllowed(uint32_t offset, uint32_t value)` whitelists only the registers and value ranges valid for your EC.
3. **`Core/NitroCore.swift` & `Core/NitroConfig.swift`**:
   - Adjust `enum Reg` offsets if any sensor offset differs on your model.
   - Adjust `FanConfig` default curve points and `failsafeTemp` to match your CPU's `CriticalTemperature`.
4. **`Makefile` & `Kext/Info.plist` & `App/Info.plist`**:
   - Set `-mmacosx-version-min` / `-target x86_64-apple-macos<version>` and `LSMinimumSystemVersion` to match your macOS version (e.g., `14.0` for macOS Sonoma).

---

### Step 5: Build, Test Read-Only First, Then Enable Writes

1. Build all targets:
   ```bash
   make clean && make
   ```
2. Install `SSDT-NITRO.aml` and `NitroEC.kext` into OpenCore (`./Scripts/install.sh`) and reboot.
3. **Before** starting `nitrod` or writing to the EC, test read-only access with `nitroctl`:
   ```bash
   ioreg -c NitroEC -w0
   ./build/nitroctl dump
   ./build/nitroctl status
   ```
4. Verify that:
   - `CPU` / `SYS` temperatures are realistic (e.g., `40–70 °C`).
   - `CPU fan` and `GPU fan` RPMs (`0x13` and `0x15`) match physical fan speeds.
   - `0x21` is `0x10` (GPU Auto) and `0x22` is `0x04` (CPU Auto).
5. Test manual fan control carefully:
   ```bash
   sudo ./build/nitroctl fan all manual 50
   ./build/nitroctl status
   sudo ./build/nitroctl fan all auto
   ```
6. Once verified, install the daemon and app:
   ```bash
   sudo ./Scripts/install-daemon.sh
   ./Scripts/install-app.sh
   ```

---
---

## Guia de Portabilidade (Português-BR)

Este guia explica passo a passo como portar o **NitroSense-macOS** para outros modelos da linha **Acer Nitro 5** (`AN515-51`, `AN515-53`, `AN515-54`, `AN515-55`, `AN515-58`, etc.), exatamente como fizemos na adaptação do `AN515-57` para o **`AN515-52`**.

### O que muda de um modelo para outro?

A maioria dos notebooks Acer Nitro 5 compartilha a mesma arquitetura de Embedded Controller (EC) da Compal/Insyde, mas há **3 diferenças principais** entre gerações:
1. **Caminhos ACPI do barramento PCI e EC**:
   - 7ª a 9ª geração Intel (`AN515-51`, `AN515-52`, `AN515-53`, `AN515-54`): `\_SB.PCI0.LPCB.EC0`, `\_SB.PCI0.LPCB.PS2K`, `\_SB.PCI0.WMID`
   - 11ª+ geração Intel (`AN515-57`, etc.): `\_SB.PC00.LPCB.EC0`, `\_SB.PC00.LPCB.PS2K`, `\_SB.PC00.WMID`
2. **Endereço físico da janela de memória do EC (`SystemMemory` / `ECMM`)**:
   - No `AN515-52`: `0xFC7E0800`
   - No `AN515-57`: `0xFE0B0800`
3. **Pequenas diferenças em registradores do EC e métodos WMI**:
   - Registrador do CoolBoost (`0x10`), sensores secundários de temperatura (`0xB3`/`0xB4`/`0x2A`) e presença ou ausência de teclado RGB de 4 zonas (`WMBH` opcodes `0x14`–`0x16`).

---

### Passo 1: Extrair e Descompilar a sua `DSDT.aml`

1. Extraia as tabelas ACPI (`DSDT.aml` e `SSDT*.aml`) do seu notebook usando o **OpenCore Debug** (`SysReport = True`), **SSDTTime** ou `acpidump` no Linux.
2. Descompile a `DSDT.aml` com o `iasl`:
   ```bash
   iasl -d DSDT.aml
   ```

---

### Passo 2: Descobrir o Caminho ACPI e o Endereço `ECMM` na `DSDT.dsl`

Procure pelo dispositivo do Embedded Controller (`PNP0C09`) na sua `DSDT.dsl`:

```bash
grep -n -C 35 "PNP0C09" DSDT.dsl
```

Você também pode confirmar os caminhos ativos no macOS rodando no terminal:

```bash
ioreg -p IOACPIPlane -w0 | grep -E "PCI0|PC00|LPCB|EC0|PS2K|WMID"
```

Dentro do `Device (EC0)` na `DSDT.dsl`, localize a região `ECMM`:

```asl
OperationRegion (ECMM, SystemMemory, 0xFC7E0800, 0x1000)
Field (ECMM, AnyAcc, Lock, Preserve)
```

Anote o endereço hexadecimal de `SystemMemory` (no exemplo do `AN515-52`, `0xFC7E0800`).

> **Atenção**: **Nunca** use o endereço `SystemMemory` de outro modelo sem antes conferir a linha `OperationRegion (ECMM, SystemMemory, ...)` na sua própria `DSDT.dsl`.

---

### Passo 3: Conferir os Registradores do EC (`DSDT.dsl` + `nbfc-linux`)

1. **Na sua `DSDT.dsl`** (dentro de `Field (ECMM, ...)`):
   Confira os offsets dos sensores:
   - `0x13` (`C1FR`, 16 bits): RPM da ventoinha da CPU
   - `0x15` (`G1FR`, 16 bits): RPM da ventoinha da GPU
   - `0x2A` (`S1TV`, 8 bits): Temperatura do sistema
   - `0xB0` (`CTMP`, 8 bits): Temperatura da CPU (°C)
   - `0xB3` (`SKTB`, 8 bits): Temperatura do socket/sistema (°C)
   - `0xB4` (`SKTC`, 8 bits) / `0xB6` (`EST1`, 8 bits): Temperatura da GPU dedicada (°C)

2. **No repositório do `nbfc-linux`**:
   Consulte a pasta `share/nbfc/configs/` do `nbfc-linux` para o seu modelo (ex.: `Acer Nitro AN515-51.json`, `Acer Nitro AN515-54.json`):
   - **Modo da ventoinha da CPU**: Registrador `34` (`0x22`) → `0x04` (Auto), `0x08` (Max), `0x0C` (Manual)
   - **Modo da ventoinha da GPU**: Registrador `33` (`0x21`) → `0x10` (Auto), `0x20` (Max), `0x30` (Manual)
   - **Velocidade manual da CPU (%)**: Registrador `55` (`0x37`) → `0` a `100`
   - **Velocidade manual da GPU (%)**: Registrador `58` (`0x3A`) → `0` a `100`
   - **CoolBoost**: Registrador `16` (`0x10`) → `0x01` (Ligado), `0x00` (Desligado)

---

### Passo 4: Adaptar o Código

1. **Em `ACPI/SSDT-NITRO.dsl`**:
   - Substitua `_SB.PCI0` (ou `_SB.PC00`) pelo caminho correto do seu notebook.
   - Substitua `0xFC7E0800` em `ERDM` e `EWB1` pelo endereço `ECMM` encontrado no Passo 2.
2. **Em `Kext/NitroEC.cpp`**:
   - Verifique a whitelist em `NitroEC::isWriteAllowed` para garantir que todos os registradores necessários para o seu modelo estejam autorizados.
3. **Em `Core/NitroCore.swift` e `Core/NitroConfig.swift`**:
   - Ajuste os offsets em `enum Reg` caso algum sensor mude no seu modelo.
   - Ajuste os pontos padrão da curva de temperatura em `FanConfig` conforme o perfil do seu processador.
4. **Em `Daemon/main.swift`**:
   - O daemon já inclui um filtro de média móvel de 6 segundos (`filterTemp`) inspirado no `TemperatureFilter` do `nbfc-linux` para evitar que picos rápidos de Turbo Boost acionem o failsafe por 2 segundos.

---

### Passo 5: Compilar e Testar com Segurança

1. Compile todos os componentes:
   ```bash
   make clean && make
   ```
2. Instale e reinicie:
   ```bash
   ./Scripts/install-all.sh
   ```
3. Após reiniciar, valide a comunicação e o dump do EC:
   ```bash
   ioreg -c NitroEC -w0
   ./build/nitroctl status
   ./build/nitroctl dump
   ```
4. Teste os modos de ventoinha (`Auto`, `Max`, `Custom` e `Curve`) pelo `NitroSense.app` ou via `nitroctl`.

