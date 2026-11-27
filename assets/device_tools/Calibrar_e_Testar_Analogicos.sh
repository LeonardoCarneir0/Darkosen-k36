#!/bin/bash
# ==============================================================================
# Calibrar_e_Testar_Analogicos.sh — darkosen-k36
# Testador visual em tempo real + Calibrador de Analogicos e Botoes A/B/X/Y.
# Mostra o que o hardware envia vs o que EmulationStation / RetroArch / SDL2
# estao entendendo, detecta inversoes ou trocas e corrige todo o sistema!
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi

export TERM=linux
export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=C
CURR_TTY="/dev/tty1"

# Para gptokeyb temporariamente para ler o controle puro sem interferencia
pkill -9 -f gptokeyb 2>/dev/null || true

for fnt in \
    /usr/share/consolefonts/Lat15-TerminusBold16.psf.gz \
    /usr/share/consolefonts/Lat7-Terminus16.psf.gz \
    /usr/share/consolefonts/Uni2-TerminusBold16.psf.gz \
    /usr/share/consolefonts/Lat7-TerminusBold20x10.psf.gz; do
    if [ -f "$fnt" ]; then
        setfont "$fnt" > "$CURR_TTY" 2>&1 || true
        break
    fi
done

cleanup() {
    printf "\033[H\033[2J\e[?25h" > "$CURR_TTY" 2>/dev/null || true
    setfont /usr/share/consolefonts/Lat7-TerminusBold22x11.psf.gz > "$CURR_TTY" 2>&1 || true
}
trap cleanup EXIT

python3 - < "$CURR_TTY" > "$CURR_TTY" 2>&1 << 'PYEOF'
import curses
import fcntl
import glob
import json
import os
import re
import select
import shutil
import struct
import time
import xml.etree.ElementTree as ET
from pathlib import Path

EV_SYN = 0x00
EV_KEY = 0x01
EV_ABS = 0x03
ABS_MAX = 0x3F
KEY_MAX = 0x2FF
EVENT_FMT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FMT)


def _IOC(dir_, type_, nr, size):
    return (dir_ << 30) | (size << 16) | (ord(type_) << 8) | nr


def EVIOCGNAME(length=128):
    return _IOC(2, "E", 0x06, length)


def EVIOCGBIT(ev, length):
    return _IOC(2, "E", 0x20 + ev, length)


def EVIOCGABS(axis):
    return _IOC(2, "E", 0x40 + axis, 24)


def test_bit(bit, buf):
    return bool(buf[bit // 8] & (1 << (bit % 8)))


class RawGamepad:
    """Reads Linux evdev directly and computes exact SDL2 / udev axis & button indices."""

    def __init__(self):
        self.fd = None
        self.path = ""
        self.name = "Nao encontrado"
        self.axes_codes = []
        self.axes_info = {}
        self.axes_norm = {}
        self.axes_raw = {}
        self.key_codes = []
        self.code_to_btn = {}
        self.pressed_btns = set()
        self.just_pressed = set()
        self._open_best_device()

    def _open_best_device(self):
        candidates = []
        for p in sorted(glob.glob("/dev/input/event*")):
            try:
                fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK)
            except OSError:
                continue
            try:
                nbuf = bytearray(128)
                fcntl.ioctl(fd, EVIOCGNAME(128), nbuf)
                name = nbuf.split(b"\x00", 1)[0].decode("utf-8", "ignore").strip()

                abs_bits = bytearray((ABS_MAX + 8) // 8)
                fcntl.ioctl(fd, EVIOCGBIT(EV_ABS, len(abs_bits)), abs_bits)
                axes = [c for c in range(ABS_MAX + 1) if test_bit(c, abs_bits)]

                key_bits = bytearray((KEY_MAX + 8) // 8)
                fcntl.ioctl(fd, EVIOCGBIT(EV_KEY, len(key_bits)), key_bits)
                btns = [c for c in range(0x100, KEY_MAX + 1) if test_bit(c, key_bits)]

                score = 0
                if "play_joystick" in name.lower() or "go-super" in name.lower() or "odroid" in name.lower():
                    score += 100
                if len(axes) >= 2:
                    score += 30
                if len(btns) >= 8:
                    score += 20
                if score > 0:
                    candidates.append((score, p, fd, name, axes, btns))
                else:
                    os.close(fd)
            except OSError:
                os.close(fd)

        if not candidates:
            return

        candidates.sort(key=lambda x: (-x[0], x[1]))
        _, self.path, self.fd, self.name, self.axes_codes, self.key_codes = candidates[0]
        for _, _, other_fd, _, _, _ in candidates[1:]:
            try:
                os.close(other_fd)
            except OSError:
                pass

        for idx, code in enumerate(self.axes_codes):
            abuf = bytearray(24)
            fcntl.ioctl(self.fd, EVIOCGABS(code), abuf)
            val, mn, mx, _fuzz, _flat, _res = struct.unpack("6i", abuf)
            if mx == mn:
                mn, mx = -1800, 1800
            self.axes_info[code] = (mn, mx)
            self.axes_raw[idx] = val
            self.axes_norm[idx] = self._normalize(val, mn, mx)

        for idx, code in enumerate(self.key_codes):
            self.code_to_btn[code] = idx

    @staticmethod
    def _normalize(val, mn, mx):
        mid = (mx + mn) / 2.0
        half = (mx - mn) / 2.0
        if half <= 0:
            return 0.0
        return max(-1.0, min(1.0, (val - mid) / half))

    def poll(self):
        self.just_pressed.clear()
        if self.fd is None:
            return
        while True:
            r, _, _ = select.select([self.fd], [], [], 0)
            if not r:
                break
            try:
                data = os.read(self.fd, EVENT_SIZE * 32)
            except (BlockingIOError, OSError):
                break
            for off in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                _sec, _usec, ev_type, ev_code, ev_val = struct.unpack_from(EVENT_FMT, data, off)
                if ev_type == EV_ABS and ev_code in self.axes_info:
                    idx = self.axes_codes.index(ev_code)
                    mn, mx = self.axes_info[ev_code]
                    self.axes_raw[idx] = ev_val
                    self.axes_norm[idx] = self._normalize(ev_val, mn, mx)
                elif ev_type == EV_KEY and ev_code in self.code_to_btn:
                    bidx = self.code_to_btn[ev_code]
                    if ev_val == 1:
                        self.pressed_btns.add(bidx)
                        self.just_pressed.add(bidx)
                    elif ev_val == 0:
                        self.pressed_btns.discard(bidx)


# ==============================================================================
# Configuration Paths & Parsers
# ==============================================================================

ES_PATHS = [
    Path("/etc/emulationstation/es_input.cfg"),
    Path("/home/ark/.emulationstation/es_input.cfg"),
    Path("/home/ark/.quirks/es_input.cfg"),
]
ES_SETTINGS_PATH = Path("/home/ark/.emulationstation/es_settings.cfg")

RA_PATHS = [
    Path("/home/ark/.config/retroarch/retroarch.cfg"),
    Path("/home/ark/.config/retroarch32/retroarch.cfg"),
]

GCDB_PATHS = [
    Path("/opt/inttools/gamecontrollerdb.txt"),
    Path("/usr/bin/emulationstation/resources/gamecontrollerdb.txt"),
    Path("/home/ark/pmk36/gamecontrollerdb.txt"),
    Path("/roms/tools/PortMaster/gamecontrollerdb.txt"),
    Path("/roms/ports/PortMaster/gamecontrollerdb.txt"),
    Path("/roms2/tools/PortMaster/gamecontrollerdb.txt"),
    Path("/roms2/ports/PortMaster/gamecontrollerdb.txt"),
]

ES_AXIS_LABELS = {
    "leftanalogup":     "ESQ CIMA",
    "leftanalogdown":   "ESQ BAIXO",
    "leftanalogleft":   "ESQ ESQUERDA",
    "leftanalogright":  "ESQ DIREITA",
    "rightanalogup":    "DIR CIMA",
    "rightanalogdown":  "DIR BAIXO",
    "rightanalogleft":  "DIR ESQUERDA",
    "rightanalogright": "DIR DIREITA",
}

ES_BTN_LABELS = {
    "a": "A", "b": "B", "x": "X", "y": "Y",
    "leftshoulder": "L1", "rightshoulder": "R1",
    "lefttrigger": "L2", "righttrigger": "R2",
    "leftthumb": "L3", "rightthumb": "R3",
    "select": "SELECT", "start": "START",
    "up": "DPAD-CIMA", "down": "DPAD-BAIXO",
    "left": "DPAD-ESQ", "right": "DPAD-DIR",
}


def load_es_full(dev_name):
    """Returns (axis_map, btn_map_id_to_names, invert_ab_menu)."""
    axes, btns = {}, {}
    invert_menu = False
    if ES_SETTINGS_PATH.exists():
        try:
            invert_menu = 'name="InvertButtons" value="true"' in ES_SETTINGS_PATH.read_text(errors="ignore")
        except Exception:
            pass

    for p in ES_PATHS:
        if not p.exists():
            continue
        try:
            root = ET.parse(p).getroot()
            target = None
            for ic in root.findall("inputConfig"):
                if ic.attrib.get("deviceName", "").lower() == dev_name.lower():
                    target = ic
                    break
            if target is None:
                ic_all = root.findall("inputConfig")
                if ic_all:
                    target = ic_all[-1]
            if target is not None:
                for inp in target.findall("input"):
                    nm = inp.attrib.get("name", "")
                    tp = inp.attrib.get("type", "")
                    if tp == "axis":
                        axes[nm] = (int(inp.attrib["id"]), int(inp.attrib["value"]))
                    elif tp == "button" and nm in ES_BTN_LABELS:
                        bid = int(inp.attrib["id"])
                        lbl = ES_BTN_LABELS[nm]
                        if lbl not in btns.get(bid, []):
                            btns.setdefault(bid, []).append(lbl)
                if axes or btns:
                    break
        except Exception:
            continue
    return axes, btns, invert_menu


def load_ra_full():
    """Returns (axis_map, btn_map_id_to_names, swap_ok_cancel)."""
    axis_keys = {
        "input_player1_l_x_minus_axis": "ESQ ESQUERDA",
        "input_player1_l_x_plus_axis":  "ESQ DIREITA",
        "input_player1_l_y_minus_axis": "ESQ CIMA",
        "input_player1_l_y_plus_axis":  "ESQ BAIXO",
        "input_player1_r_x_minus_axis": "DIR ESQUERDA",
        "input_player1_r_x_plus_axis":  "DIR DIREITA",
        "input_player1_r_y_minus_axis": "DIR CIMA",
        "input_player1_r_y_plus_axis":  "DIR BAIXO",
    }
    btn_keys = {
        "input_player1_a_btn": "A",
        "input_player1_b_btn": "B",
        "input_player1_x_btn": "X",
        "input_player1_y_btn": "Y",
        "input_player1_l_btn": "L1",
        "input_player1_r_btn": "R1",
        "input_player1_l2_btn": "L2",
        "input_player1_r2_btn": "R2",
        "input_player1_l3_btn": "L3",
        "input_player1_r3_btn": "R3",
        "input_player1_select_btn": "SELECT",
        "input_player1_start_btn": "START",
        "input_player1_up_btn": "DPAD-CIMA",
        "input_player1_down_btn": "DPAD-BAIXO",
        "input_player1_left_btn": "DPAD-ESQ",
        "input_player1_right_btn": "DPAD-DIR",
    }
    axes, btns = {}, {}
    swap_ok = False
    for p in RA_PATHS:
        if not p.exists():
            continue
        try:
            for line in p.read_text(errors="ignore").splitlines():
                if "=" not in line:
                    continue
                k, v = [x.strip().strip('"') for x in line.split("=", 1)]
                if k == "menu_swap_ok_cancel_buttons":
                    swap_ok = v.lower() == "true"
                elif k in axis_keys and v not in ("nul", ""):
                    m = re.match(r"^([+-]?)(\d+)$", v)
                    if m:
                        axes[axis_keys[k]] = (int(m.group(2)), -1 if m.group(1) == "-" else 1)
                elif k in btn_keys and v.isdigit():
                    btns.setdefault(int(v), []).append(btn_keys[k])
            if axes or btns:
                break
        except Exception:
            continue
    return axes, btns, swap_ok


def load_sdl_full(dev_name):
    """Returns (axis_map, btn_map_id_to_names) from gamecontrollerdb.txt."""
    axes, btns = {}, {}
    sdl_btn_names = {
        "a": "SDL-A", "b": "SDL-B", "x": "SDL-X", "y": "SDL-Y",
        "leftshoulder": "L1", "rightshoulder": "R1",
        "lefttrigger": "L2", "righttrigger": "R2",
        "leftstick": "L3", "rightstick": "R3",
        "back": "SELECT", "start": "START", "guide": "FN",
        "dpup": "DPAD-CIMA", "dpdown": "DPAD-BAIXO",
        "dpleft": "DPAD-ESQ", "dpright": "DPAD-DIR",
    }
    for p in GCDB_PATHS:
        if not p.exists():
            continue
        try:
            for line in p.read_text(errors="ignore").splitlines():
                if f",{dev_name}," in line or "play_joystick" in line:
                    for tok in line.split(","):
                        if ":" not in tok:
                            continue
                        k, v = tok.split(":", 1)
                        v = v.strip()
                        ma = re.match(r"^([+-]?)a(\d+)(~?)$", v)
                        mb = re.match(r"^b(\d+)$", v)
                        if ma:
                            ax = int(ma.group(2))
                            inv = -1 if ma.group(3) == "~" else 1
                            if k == "leftx":
                                axes["ESQ ESQUERDA"] = (ax, -1 * inv)
                                axes["ESQ DIREITA"]  = (ax, +1 * inv)
                            elif k == "lefty":
                                axes["ESQ CIMA"]     = (ax, -1 * inv)
                                axes["ESQ BAIXO"]    = (ax, +1 * inv)
                            elif k == "rightx":
                                axes["DIR ESQUERDA"] = (ax, -1 * inv)
                                axes["DIR DIREITA"]  = (ax, +1 * inv)
                            elif k == "righty":
                                axes["DIR CIMA"]     = (ax, -1 * inv)
                                axes["DIR BAIXO"]    = (ax, +1 * inv)
                        elif mb and k in sdl_btn_names:
                            btns.setdefault(int(mb.group(1)), []).append(sdl_btn_names[k])
                    if axes or btns:
                        return axes, btns
        except Exception:
            continue
    return axes, btns


def interpret_state(axes_map, btns_map, axes_norm, pressed_btns, is_es=False, deadzone=0.38):
    parts = []
    for k, (ax, sgn) in axes_map.items():
        val = axes_norm.get(ax, 0.0)
        if abs(val) >= deadzone and (val * sgn) > 0:
            parts.append(ES_AXIS_LABELS.get(k, k) if is_es else k)
    for b in sorted(pressed_btns):
        if b in btns_map:
            parts.append("Btn " + "/".join(btns_map[b]))
        else:
            parts.append(f"b{b}(sem mapa)")
    return " + ".join(parts) if parts else "(parado)"


# ==============================================================================
# System-Wide Patchers (Analogs & A/B/X/Y Buttons)
# ==============================================================================

def _update_gcdb_tokens(dev_name, token_updates):
    """Updates specific key:val tokens on the play_joystick line across all gamecontrollerdb.txt files."""
    updated = []
    default_line = (
        f"19000f6a706c61795f6a6f7973746900,{dev_name},"
        "a:b0,b:b1,x:b2,y:b3,back:b8,guide:b10,start:b9,"
        "leftstick:b11,rightstick:b12,leftshoulder:b4,rightshoulder:b5,"
        "dpup:b14,dpdown:b15,dpleft:b16,dpright:b17,"
        "leftx:a0,lefty:a3,rightx:a2,righty:a1,lefttrigger:b6,righttrigger:b7,platform:Linux,"
    )
    final_line = ""
    for p in GCDB_PATHS:
        if not p.exists():
            continue
        try:
            lines = p.read_text(errors="ignore").splitlines()
            out = []
            replaced = False
            for line in lines:
                if "19000f6a706c61795f6a6f7973746900" in line or f",{dev_name}," in line:
                    if not replaced:
                        toks = [t for t in line.split(",") if t]
                        new_toks = []
                        seen = set()
                        for idx, t in enumerate(toks):
                            if idx >= 2 and ":" in t:
                                k, _ = t.split(":", 1)
                                if k in token_updates:
                                    new_toks.append(f"{k}:{token_updates[k]}")
                                    seen.add(k)
                                    continue
                            new_toks.append(t)
                        for k, val in token_updates.items():
                            if k not in seen:
                                new_toks.insert(-1, f"{k}:{val}")
                        final_line = ",".join(new_toks) + ","
                        out.append(final_line)
                        replaced = True
                else:
                    out.append(line)
            if not replaced:
                toks = [t for t in default_line.split(",") if t]
                new_toks = []
                for idx, t in enumerate(toks):
                    if idx >= 2 and ":" in t:
                        k, _ = t.split(":", 1)
                        if k in token_updates:
                            new_toks.append(f"{k}:{token_updates[k]}")
                            continue
                    new_toks.append(t)
                final_line = ",".join(new_toks) + ","
                out.append(final_line)
            p.write_text("\n".join(out) + "\n")
            updated.append(str(p))
        except Exception:
            pass
    return updated, final_line


def _save_report(section_name, payload):
    for rdir in [Path("/roms/tools"), Path("/roms2/tools"), Path("/tmp")]:
        if rdir.is_dir():
            try:
                jpath = rdir / "relatorio_controles.json"
                data = {}
                if jpath.exists():
                    try:
                        data = json.loads(jpath.read_text())
                    except Exception:
                        data = {}
                data[section_name] = payload
                data["updated_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
                jpath.write_text(json.dumps(data, indent=2))

                lines = [
                    "============================================================",
                    " RELATORIO DE CALIBRACAO DE CONTROLES - darkosen-k36",
                    f" Atualizado em: {data['updated_at']}",
                    "============================================================",
                    json.dumps(data, indent=2),
                ]
                (rdir / "relatorio_controles.txt").write_text("\n".join(lines) + "\n")
                break
            except Exception:
                continue


def apply_analog_calibration(dev_name, cal):
    lx, lx_r = cal["lx_axis"], cal["lx_right_sign"]
    ly, ly_u = cal["ly_axis"], cal["ly_up_sign"]
    rx, rx_r = cal["rx_axis"], cal["rx_right_sign"]
    ry, ry_u = cal["ry_axis"], cal["ry_up_sign"]
    lx_l, ly_d, rx_l, ry_d = -lx_r, -ly_u, -rx_r, -ry_u

    updated = []

    # 1. EmulationStation
    es_updates = {
        "leftanalogleft":   (str(lx), str(lx_l)),
        "leftanalogright":  (str(lx), str(lx_r)),
        "leftanalogup":     (str(ly), str(ly_u)),
        "leftanalogdown":   (str(ly), str(ly_d)),
        "rightanalogleft":  (str(rx), str(rx_l)),
        "rightanalogright": (str(rx), str(rx_r)),
        "rightanalogup":    (str(ry), str(ry_u)),
        "rightanalogdown":  (str(ry), str(ry_d)),
    }
    for p in ES_PATHS:
        if not p.exists():
            continue
        try:
            txt = p.read_text(errors="ignore")
            shutil.copy2(p, str(p) + ".bak_cal")
            for name, (aid, aval) in es_updates.items():
                txt = re.sub(
                    rf'(<input\s+name="{name}"\s+type="axis"\s+id=")\d+("\s+value=")-?\d+("\s*/>)',
                    rf"\g<1>{aid}\g<2>{aval}\g<3>",
                    txt,
                )
            if cal.get("l3_btn") is not None:
                txt = re.sub(r'(<input\s+name="leftthumb"\s+type="button"\s+id=")\d+(")', rf'\g<1>{cal["l3_btn"]}\g<2>', txt)
            if cal.get("r3_btn") is not None:
                txt = re.sub(r'(<input\s+name="rightthumb"\s+type="button"\s+id=")\d+(")', rf'\g<1>{cal["r3_btn"]}\g<2>', txt)
            p.write_text(txt)
            updated.append(str(p))
        except Exception:
            pass

    # 2. RetroArch 64/32
    fmt_ra = lambda ax, sgn: f'"{("+" if sgn > 0 else "-")}{ax}"'
    ra_kv = {
        "input_player1_l_x_minus_axis": fmt_ra(lx, lx_l),
        "input_player1_l_x_plus_axis":  fmt_ra(lx, lx_r),
        "input_player1_l_y_minus_axis": fmt_ra(ly, ly_u),
        "input_player1_l_y_plus_axis":  fmt_ra(ly, ly_d),
        "input_player1_r_x_minus_axis": fmt_ra(rx, rx_l),
        "input_player1_r_x_plus_axis":  fmt_ra(rx, rx_r),
        "input_player1_r_y_minus_axis": fmt_ra(ry, ry_u),
        "input_player1_r_y_plus_axis":  fmt_ra(ry, ry_d),
    }
    if cal.get("l3_btn") is not None:
        ra_kv["input_player1_l3_btn"] = f'"{cal["l3_btn"]}"'
    if cal.get("r3_btn") is not None:
        ra_kv["input_player1_r3_btn"] = f'"{cal["r3_btn"]}"'

    extra_ra = [Path(x) for x in glob.glob("/home/ark/.config/retroarch*/autoconfig/udev/*.cfg")]
    for p in RA_PATHS + extra_ra:
        if not p.exists():
            continue
        try:
            txt = p.read_text(errors="ignore")
            if p not in RA_PATHS and dev_name.lower() not in txt.lower():
                continue
            shutil.copy2(p, str(p) + ".bak_cal")
            lines = txt.splitlines(keepends=True)
            seen, out = set(), []
            for line in lines:
                m = re.match(r"^\s*([a-zA-Z0-9_]+)\s*=", line)
                if m and m.group(1) in ra_kv:
                    k = m.group(1)
                    out.append(f"{k} = {ra_kv[k]}\n")
                    seen.add(k)
                else:
                    out.append(line)
            for k, v in ra_kv.items():
                if k not in seen and p in RA_PATHS:
                    out.append(f"{k} = {v}\n")
            p.write_text("".join(out))
            updated.append(str(p))
        except Exception:
            pass

    # 3. SDL2 gamecontrollerdb.txt
    toks = {
        "leftx":  f"a{lx}{'' if lx_r == 1 else '~'}",
        "lefty":  f"a{ly}{'' if ly_u == -1 else '~'}",
        "rightx": f"a{rx}{'' if rx_r == 1 else '~'}",
        "righty": f"a{ry}{'' if ry_u == -1 else '~'}",
    }
    if cal.get("l3_btn") is not None:
        toks["leftstick"] = f"b{cal['l3_btn']}"
    if cal.get("r3_btn") is not None:
        toks["rightstick"] = f"b{cal['r3_btn']}"

    gc_up, gcdb_line = _update_gcdb_tokens(dev_name, toks)
    updated.extend(gc_up)

    # 4. Mupen64Plus
    for mp in [Path("/home/ark/.config/mupen64plus/mupen64plus.cfg"), Path("/opt/mupen64plus/InputAutoCfg.ini")]:
        if mp.exists():
            try:
                txt = mp.read_text(errors="ignore")
                x_pair = f"axis({lx}{'-' if lx_l < 0 else '+'},{lx}{'+' if lx_r > 0 else '-'})"
                y_pair = f"axis({ly}{'-' if ly_u < 0 else '+'},{ly}{'+' if ly_d > 0 else '-'})"
                txt2 = re.sub(r"X Axis\s*=\s*\"?axis\([^)\n]+\)\"?", f'X Axis = "{x_pair}"', txt)
                txt2 = re.sub(r"Y Axis\s*=\s*\"?axis\([^)\n]+\)\"?", f'Y Axis = "{y_pair}"', txt2)
                if txt2 != txt:
                    mp.write_text(txt2)
                    updated.append(str(mp))
            except Exception:
                pass

    os.system("chown -R 1000:1000 /home/ark/.config /home/ark/.emulationstation /home/ark/.quirks /home/ark/pmk36 2>/dev/null || true")
    _save_report("analogs", {"calibration": cal, "sdl_tokens": toks, "gcdb_line": gcdb_line, "updated_files": updated})
    return updated, toks["leftx"], toks["lefty"], toks["rightx"], toks["righty"]


def apply_abxy_calibration(dev_name, bcal):
    """
    bcal = {
      'a': int (physical right button),
      'b': int (physical bottom button),
      'x': int (physical top button),
      'y': int (physical left button),
      'swap_confirm': bool (False = A confirms / B backs; True = B confirms / A backs)
    }
    """
    ba, bb, bx, by = bcal["a"], bcal["b"], bcal["x"], bcal["y"]
    swap_confirm = bool(bcal.get("swap_confirm", False))
    updated = []

    # 1. EmulationStation es_input.cfg + es_settings.cfg (InvertButtons)
    for p in ES_PATHS:
        if not p.exists():
            continue
        try:
            txt = p.read_text(errors="ignore")
            shutil.copy2(p, str(p) + ".bak_cal")
            for nm, bid in (("a", ba), ("b", bb), ("x", bx), ("y", by)):
                txt = re.sub(rf'(<input\s+name="{nm}"\s+type="button"\s+id=")\d+(")', rf"\g<1>{bid}\g<2>", txt)
            p.write_text(txt)
            updated.append(str(p))
        except Exception:
            pass

    if ES_SETTINGS_PATH.exists():
        try:
            st = ES_SETTINGS_PATH.read_text(errors="ignore")
            want = "true" if swap_confirm else "false"
            if 'name="InvertButtons"' in st:
                st = re.sub(r'<bool\s+name="InvertButtons"\s+value="(true|false)"\s*/>', f'<bool name="InvertButtons" value="{want}" />', st)
            else:
                st = st.rstrip() + f'\n\t<bool name="InvertButtons" value="{want}" />\n'
            ES_SETTINGS_PATH.write_text(st)
            updated.append(str(ES_SETTINGS_PATH))
        except Exception:
            pass

    # 2. RetroArch 64/32
    ra_kv = {
        "input_player1_a_btn": f'"{ba}"',
        "input_player1_b_btn": f'"{bb}"',
        "input_player1_x_btn": f'"{bx}"',
        "input_player1_y_btn": f'"{by}"',
        "menu_swap_ok_cancel_buttons": '"true"' if swap_confirm else '"false"',
    }
    extra_ra = [Path(x) for x in glob.glob("/home/ark/.config/retroarch*/autoconfig/udev/*.cfg")]
    for p in RA_PATHS + extra_ra:
        if not p.exists():
            continue
        try:
            txt = p.read_text(errors="ignore")
            if p not in RA_PATHS and dev_name.lower() not in txt.lower():
                continue
            shutil.copy2(p, str(p) + ".bak_cal")
            lines = txt.splitlines(keepends=True)
            seen, out = set(), []
            for line in lines:
                m = re.match(r"^\s*([a-zA-Z0-9_]+)\s*=", line)
                if m and m.group(1) in ra_kv:
                    k = m.group(1)
                    out.append(f"{k} = {ra_kv[k]}\n")
                    seen.add(k)
                else:
                    out.append(line)
            for k, v in ra_kv.items():
                if k not in seen and p in RA_PATHS:
                    out.append(f"{k} = {v}\n")
            p.write_text("".join(out))
            updated.append(str(p))
        except Exception:
            pass

    # 3. PortMaster / SDL2 gamecontrollerdb.txt (ArkOS/PortMaster convention matches RetroPad a/b/x/y)
    toks = {"a": f"b{ba}", "b": f"b{bb}", "x": f"b{bx}", "y": f"b{by}"}
    gc_up, gcdb_line = _update_gcdb_tokens(dev_name, toks)
    updated.extend(gc_up)

    os.system("chown -R 1000:1000 /home/ark/.config /home/ark/.emulationstation /home/ark/.quirks /home/ark/pmk36 2>/dev/null || true")
    _save_report("buttons_abxy", {"calibration": bcal, "gcdb_line": gcdb_line, "updated_files": updated})
    return updated


# ==============================================================================
# Curses UI Helpers & Wizards
# ==============================================================================

def safe_addstr(stdscr, y, x, text, attr=0):
    h, w = stdscr.getmaxyx()
    if y < 0 or y >= h or x >= w:
        return
    clipped = text[: max(0, w - x - 1)]
    if clipped:
        try:
            stdscr.addstr(y, x, clipped, attr)
        except curses.error:
            pass


def bar_str(val, width=13):
    half = width // 2
    pos = max(0, min(width - 1, int(round((val + 1.0) / 2.0 * (width - 1)))))
    chars = ["-"] * width
    chars[half] = "|"
    chars[pos] = "#"
    return "[" + "".join(chars) + f"] {int(round(val * 100)):+4d}%"


def capture_axis_step(stdscr, gp, step_title, instruction, baseline, forbidden_axes=None):
    forbidden_axes = forbidden_axes or set()
    while True:
        gp.poll()
        ch = stdscr.getch()
        if 8 in gp.just_pressed or ch == 27:  # SELECT or ESC cancels
            return None, None

        best_ax, best_delta = None, 0.0
        for ax, val in gp.axes_norm.items():
            delta = val - baseline.get(ax, 0.0)
            if abs(delta) > abs(best_delta):
                best_ax, best_delta = ax, delta

        # Confirm with A (0), B (1), START (9) or Enter while holding stick
        confirm = bool(gp.just_pressed & {0, 1, 9}) or (ch in (10, 13, ord("a"), ord("A")))
        if confirm and best_ax is not None and abs(best_delta) >= 0.45 and best_ax not in forbidden_axes:
            return best_ax, (1 if best_delta > 0 else -1)

        stdscr.erase()
        safe_addstr(stdscr, 0, 1, "=== CALIBRACAO DOS ANALOGICOS ===", curses.A_BOLD | curses.color_pair(3))
        safe_addstr(stdscr, 2, 1, step_title, curses.A_BOLD | curses.color_pair(2))
        for idx, line in enumerate(instruction.splitlines()):
            safe_addstr(stdscr, 4 + idx, 1, line, curses.A_BOLD)

        for ax in sorted(gp.axes_norm.keys())[:6]:
            v = gp.axes_norm[ax]
            mark = " <-- DETECTADO!" if (ax == best_ax and abs(best_delta) >= 0.45) else ""
            if ax in forbidden_axes and ax == best_ax and abs(best_delta) >= 0.45:
                mark = " <-- (eixo ja usado!)"
            attr = curses.color_pair(2) | curses.A_BOLD if "DETECTADO" in mark else 0
            safe_addstr(stdscr, 8 + ax, 2, f"Eixo a{ax}: {bar_str(v)}{mark}", attr)

        if best_ax is not None and abs(best_delta) >= 0.45 and best_ax not in forbidden_axes:
            safe_addstr(stdscr, 15, 1, f"Pronto! Segure firme (a{best_ax} {'+' if best_delta > 0 else '-'}) e aperte [A] ou [START]!", curses.color_pair(2) | curses.A_BOLD)
        else:
            safe_addstr(stdscr, 15, 1, "Empurre o analogico ate passar de 50% e aperte [A]...", curses.color_pair(4))

        safe_addstr(stdscr, 17, 1, "[A / START] Confirmar leitura    [SELECT] Cancelar", curses.A_DIM)
        stdscr.refresh()
        time.sleep(0.03)


def capture_single_btn(stdscr, gp, title, prompt, forbidden_btns=None):
    forbidden_btns = forbidden_btns or set()
    # Ignore D-Pad (14..17) and Select/Start (8,9) when capturing A/B/X/Y/L3/R3
    system_btns = {8, 9, 14, 15, 16, 17}
    while True:
        gp.poll()
        ch = stdscr.getch()
        if 8 in gp.just_pressed or ch == 27:  # SELECT = cancel/skip
            return None
        for b in sorted(gp.just_pressed):
            if b not in system_btns and b not in forbidden_btns:
                return b

        stdscr.erase()
        safe_addstr(stdscr, 0, 1, title, curses.A_BOLD | curses.color_pair(3))
        for idx, line in enumerate(prompt.splitlines()):
            safe_addstr(stdscr, 3 + idx, 1, line, curses.A_BOLD | curses.color_pair(2))
        safe_addstr(stdscr, 8, 1, f"Botoes ativos agora: {sorted(gp.pressed_btns) or 'nenhum'}")
        if forbidden_btns:
            safe_addstr(stdscr, 9, 1, f"Ja capturados: {sorted(forbidden_btns)}", curses.A_DIM)
        safe_addstr(stdscr, 12, 1, "[SELECT] Cancelar / Pular", curses.A_DIM)
        stdscr.refresh()
        time.sleep(0.03)


def run_analog_wizard(stdscr, gp):
    while True:
        gp.poll()
        ch = stdscr.getch()
        if 8 in gp.just_pressed or ch == 27:
            return None
        if bool(gp.just_pressed & {0, 1, 9}) or ch in (10, 13, ord("a"), ord("A")):
            baseline = dict(gp.axes_norm)
            break
        stdscr.erase()
        safe_addstr(stdscr, 0, 1, "=== CALIBRACAO ANALOGICOS (PASSO 1/6) ===", curses.A_BOLD | curses.color_pair(3))
        safe_addstr(stdscr, 2, 1, "SOLTE os dois analogicos no centro (repouso)", curses.A_BOLD | curses.color_pair(2))
        safe_addstr(stdscr, 3, 1, "e aperte [A] ou [START] para gravar o ponto zero.")
        for ax in sorted(gp.axes_norm.keys())[:6]:
            safe_addstr(stdscr, 6 + ax, 2, f"Eixo a{ax}: {bar_str(gp.axes_norm[ax])}")
        safe_addstr(stdscr, 14, 1, "[A / START] Gravar centro    [SELECT] Cancelar", curses.A_DIM)
        stdscr.refresh()
        time.sleep(0.03)

    time.sleep(0.25)
    gp.poll()
    used = set()

    ly_ax, ly_up = capture_axis_step(stdscr, gp, "PASSO 2/6: ANALOGICO ESQUERDO -> CIMA (^)", "Segure o ANALOGICO ESQUERDO todo para CIMA\ne aperte [A] ou [START]!", baseline, used)
    if ly_ax is None:
        return None
    used.add(ly_ax)
    time.sleep(0.25)

    lx_ax, lx_right = capture_axis_step(stdscr, gp, "PASSO 3/6: ANALOGICO ESQUERDO -> DIREITA (>)", "Segure o ANALOGICO ESQUERDO todo para DIREITA\ne aperte [A] ou [START]!", baseline, used)
    if lx_ax is None:
        return None
    used.add(lx_ax)
    time.sleep(0.25)

    ry_ax, ry_up = capture_axis_step(stdscr, gp, "PASSO 4/6: ANALOGICO DIREITO -> CIMA (^)", "Segure o ANALOGICO DIREITO todo para CIMA\ne aperte [A] ou [START]!", baseline, used)
    if ry_ax is None:
        return None
    used.add(ry_ax)
    time.sleep(0.25)

    rx_ax, rx_right = capture_axis_step(stdscr, gp, "PASSO 5/6: ANALOGICO DIREITO -> DIREITA (>)", "Segure o ANALOGICO DIREITO todo para DIREITA\ne aperte [A] ou [START]!", baseline, used)
    if rx_ax is None:
        return None
    time.sleep(0.25)

    l3_btn = capture_single_btn(stdscr, gp, "=== PASSO 6/6 (Opcional): CLIQUE L3 ===", "Aperte o clique do ANALOGICO ESQUERDO (L3)\n(ou aperte [SELECT] para manter o padrao):", {0, 1, 2, 3, 4, 5, 6, 7})
    time.sleep(0.25)
    r3_btn = capture_single_btn(stdscr, gp, "=== PASSO 6/6 (Opcional): CLIQUE R3 ===", "Aperte o clique do ANALOGICO DIREITO (R3)\n(ou aperte [SELECT] para manter o padrao):", {0, 1, 2, 3, 4, 5, 6, 7} | ({l3_btn} if l3_btn is not None else set()))
    time.sleep(0.25)

    cal = {
        "lx_axis": lx_ax, "lx_right_sign": lx_right,
        "ly_axis": ly_ax, "ly_up_sign":    ly_up,
        "rx_axis": rx_ax, "rx_right_sign": rx_right,
        "ry_axis": ry_ax, "ry_up_sign":    ry_up,
        "l3_btn":  l3_btn, "r3_btn":       r3_btn,
    }

    while True:
        gp.poll()
        ch = stdscr.getch()
        if 8 in gp.just_pressed or ch == 27:
            return None
        if 9 in gp.just_pressed or 0 in gp.just_pressed or ch in (10, 13):
            return cal

        stdscr.erase()
        safe_addstr(stdscr, 0, 1, "=== RESUMO DOS ANALOGICOS DETECTADOS ===", curses.A_BOLD | curses.color_pair(3))
        safe_addstr(stdscr, 2, 1, f"ESQ Horizontal: a{lx_ax} | Direita={'+' if lx_right > 0 else '-'} ({'NORMAL' if lx_right == 1 else 'INVERTIDO'})")
        safe_addstr(stdscr, 3, 1, f"ESQ Vertical  : a{ly_ax} | Cima={'+' if ly_up > 0 else '-'}    ({'NORMAL' if ly_up == -1 else 'INVERTIDO'})")
        safe_addstr(stdscr, 4, 1, f"DIR Horizontal: a{rx_ax} | Direita={'+' if rx_right > 0 else '-'} ({'NORMAL' if rx_right == 1 else 'INVERTIDO'})")
        safe_addstr(stdscr, 5, 1, f"DIR Vertical  : a{ry_ax} | Cima={'+' if ry_up > 0 else '-'}    ({'NORMAL' if ry_up == -1 else 'INVERTIDO'})")
        safe_addstr(stdscr, 6, 1, f"L3 / R3       : L3={l3_btn if l3_btn is not None else 'padrao'} | R3={r3_btn if r3_btn is not None else 'padrao'}")
        safe_addstr(stdscr, 9, 1, "[START ou A] APLICAR EM TODO O SISTEMA    [SELECT] Cancelar", curses.A_BOLD | curses.color_pair(2))
        stdscr.refresh()
        time.sleep(0.03)


def run_abxy_wizard(stdscr, gp):
    used = set()
    ba = capture_single_btn(stdscr, gp, "=== CALIBRAR A / B / X / Y (1/5) ===", "Aperte o botao fisico [A] (DIREITA / Leste na carcaca):", used)
    if ba is None:
        return None
    used.add(ba)
    time.sleep(0.25)

    bb = capture_single_btn(stdscr, gp, "=== CALIBRAR A / B / X / Y (2/5) ===", "Aperte o botao fisico [B] (BAIXO / Sul na carcaca):", used)
    if bb is None:
        return None
    used.add(bb)
    time.sleep(0.25)

    bx = capture_single_btn(stdscr, gp, "=== CALIBRAR A / B / X / Y (3/5) ===", "Aperte o botao fisico [X] (CIMA / Norte na carcaca):", used)
    if bx is None:
        return None
    used.add(bx)
    time.sleep(0.25)

    by = capture_single_btn(stdscr, gp, "=== CALIBRAR A / B / X / Y (4/5) ===", "Aperte o botao fisico [Y] (ESQUERDA / Oeste na carcaca):", used)
    if by is None:
        return None
    time.sleep(0.25)

    swap_confirm = False
    while True:
        gp.poll()
        ch = stdscr.getch()
        if 8 in gp.just_pressed or ch == 27:
            return None
        if 14 in gp.just_pressed or 15 in gp.just_pressed or ch in (curses.KEY_UP, curses.KEY_DOWN):
            swap_confirm = not swap_confirm
        if 9 in gp.just_pressed or ba in gp.just_pressed or ch in (10, 13):
            return {"a": ba, "b": bb, "x": bx, "y": by, "swap_confirm": swap_confirm}

        stdscr.erase()
        safe_addstr(stdscr, 0, 1, "=== CALIBRAR A / B / X / Y (5/5) ===", curses.A_BOLD | curses.color_pair(3))
        safe_addstr(stdscr, 2, 1, f"Detectado: A(Dir)=b{ba} | B(Baixo)=b{bb} | X(Cima)=b{bx} | Y(Esq)=b{by}", curses.A_BOLD)
        safe_addstr(stdscr, 4, 1, "Como voce prefere CONFIRMAR e VOLTAR nos menus (ES + RetroArch)?")
        opt0 = f" {'>>' if not swap_confirm else '  '} [Padrao Nintendo/R36S] Botao A (Direita) Confirma | B (Baixo) Volta"
        opt1 = f" {'>>' if swap_confirm else '  '} [Estilo PlayStation/Xbox] Botao B (Baixo) Confirma | A (Direita) Volta"
        safe_addstr(stdscr, 6, 1, opt0, curses.color_pair(2) | curses.A_BOLD if not swap_confirm else 0)
        safe_addstr(stdscr, 7, 1, opt1, curses.color_pair(2) | curses.A_BOLD if swap_confirm else 0)
        safe_addstr(stdscr, 10, 1, "[DPAD Cima/Baixo] Escolher   [START] Aplicar   [SELECT] Cancelar", curses.A_DIM)
        stdscr.refresh()
        time.sleep(0.03)


def main(stdscr):
    curses.curs_set(0)
    stdscr.nodelay(True)
    stdscr.keypad(True)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_WHITE, -1)
    curses.init_pair(2, curses.COLOR_GREEN, -1)
    curses.init_pair(3, curses.COLOR_CYAN, -1)
    curses.init_pair(4, curses.COLOR_YELLOW, -1)
    curses.init_pair(5, curses.COLOR_RED, -1)

    gp = RawGamepad()
    es_axes, es_btns, es_inv = load_es_full(gp.name)
    ra_axes, ra_btns, ra_swap = load_ra_full()
    sdl_axes, sdl_btns = load_sdl_full(gp.name)
    status_msg = ""

    while True:
        gp.poll()
        ch = stdscr.getch()

        # Exit on START + SELECT held together, or Q
        if (8 in gp.pressed_btns and 9 in gp.pressed_btns) or ch in (ord("q"), ord("Q")):
            break

        # Shortcuts using L1 (btn 4) = Calibrar Analogicos, R1 (btn 5) = Calibrar A/B/X/Y
        # So the user can freely test pressing A, B, X, Y on the main screen without accidentally opening a menu!
        if 4 in gp.just_pressed or ch in (ord("1"),):
            cal = run_analog_wizard(stdscr, gp)
            if cal is not None:
                updated, slx, sly, srx, sry = apply_analog_calibration(gp.name, cal)
                es_axes, es_btns, es_inv = load_es_full(gp.name)
                ra_axes, ra_btns, ra_swap = load_ra_full()
                sdl_axes, sdl_btns = load_sdl_full(gp.name)
                status_msg = f"ANALOGICOS SALVOS! ({len(updated)} arqs | {slx},{sly},{srx},{sry})"
            else:
                status_msg = "Calibracao de analogicos cancelada."

        if 5 in gp.just_pressed or ch in (ord("2"),):
            bcal = run_abxy_wizard(stdscr, gp)
            if bcal is not None:
                updated = apply_abxy_calibration(gp.name, bcal)
                es_axes, es_btns, es_inv = load_es_full(gp.name)
                ra_axes, ra_btns, ra_swap = load_ra_full()
                sdl_axes, sdl_btns = load_sdl_full(gp.name)
                status_msg = f"BOTOES A/B/X/Y SALVOS! ({len(updated)} arquivos atualizados)"
            else:
                status_msg = "Calibracao A/B/X/Y cancelada."

        stdscr.erase()
        safe_addstr(stdscr, 0, 1, f"darkosen-k36 | Testador & Calibrador: {gp.name}", curses.A_BOLD | curses.color_pair(3))

        # 1. Raw Hardware
        safe_addstr(stdscr, 2, 1, "1) HARDWARE BRUTO (mexa os analogicos ou aperte A/B/X/Y):", curses.A_BOLD)
        for ax in range(min(4, len(gp.axes_codes))):
            v = gp.axes_norm.get(ax, 0.0)
            attr = curses.color_pair(2) | curses.A_BOLD if abs(v) >= 0.38 else 0
            safe_addstr(stdscr, 3 + ax, 3, f"Eixo a{ax}: {bar_str(v)}", attr)
        btns_txt = ", ".join(f"b{b}" for b in sorted(gp.pressed_btns)) or "(nenhum)"
        safe_addstr(stdscr, 7, 3, f"Botoes brutos ativos: {btns_txt}", curses.color_pair(2) | curses.A_BOLD if gp.pressed_btns else 0)

        # 2. System Interpretation (Analogs + Buttons!)
        es_now = interpret_state(es_axes, es_btns, gp.axes_norm, gp.pressed_btns, is_es=True)
        ra_now = interpret_state(ra_axes, ra_btns, gp.axes_norm, gp.pressed_btns, is_es=False)
        sdl_now = interpret_state(sdl_axes, sdl_btns, gp.axes_norm, gp.pressed_btns, is_es=False)
        es_ok_lbl = "B confirma" if es_inv else "A confirma"
        ra_ok_lbl = "B confirma" if ra_swap else "A confirma"

        safe_addstr(stdscr, 9, 1, "2) O QUE O SISTEMA ENTENDE AGORA:", curses.A_BOLD)
        safe_addstr(stdscr, 10, 3, f"Menu ES ({es_ok_lbl})   : {es_now}", curses.color_pair(2) | curses.A_BOLD if es_now != "(parado)" else 0)
        safe_addstr(stdscr, 11, 3, f"RetroArch ({ra_ok_lbl}) : {ra_now}", curses.color_pair(2) | curses.A_BOLD if ra_now != "(parado)" else 0)
        safe_addstr(stdscr, 12, 3, f"SDL2 / PortMaster     : {sdl_now}", curses.color_pair(2) | curses.A_BOLD if sdl_now != "(parado)" else 0)

        if status_msg:
            safe_addstr(stdscr, 14, 1, status_msg, curses.color_pair(2) | curses.A_BOLD)
        else:
            safe_addstr(stdscr, 14, 1, "Teste livremente A, B, X, Y e os 2 analogicos na tela acima!", curses.color_pair(4))

        safe_addstr(stdscr, 16, 1, "[L1] Calibrar Analogicos    [R1] Calibrar Botoes A/B/X/Y", curses.A_BOLD | curses.color_pair(2))
        safe_addstr(stdscr, 17, 1, "[SELECT + START juntos] Sair", curses.A_DIM)

        stdscr.refresh()
        time.sleep(0.03)


curses.wrapper(main)
PYEOF

exit 0
