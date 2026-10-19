"""Fill in the surface ramp of every theme in ``app/themes.json``.

A theme is an accent plus the surfaces the clients paint with. The surfaces are
Tailwind's *slate* steps with the accent's hue: every step keeps slate's
lightness, so text, muted text and borders keep exactly the contrast they were
designed with, and only the colour cast changes.

Run this after adding or editing an accent::

    .venv/bin/python generate_theme_surfaces.py

It rewrites the ``"surface"`` block of each theme (``50``…``950`` plus ``card``,
the light-mode panel colour). Re-running it is safe: the ramp depends only on
the accent, never on the previous ramp. The mirror in ``mobile/lib/src/theme.dart``
is *not* touched — copy the new values there and ``mobile/test/theme_sync_test.dart``
will confirm the two agree.

The maths is OKLCh (the perceptually uniform form of OKLab): take the accent's
hue, keep slate's lightness, and use a slightly stronger chroma than slate so the
tint is visible without shouting. Gray's accent is effectively neutral, so its
surfaces stay a true grey.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

THEMES_FILE = Path(__file__).resolve().parent / "app" / "themes.json"

#: Tailwind slate — the ramp the apps were designed against.
SLATE = {
    50: "#f8fafc",
    100: "#f1f5f9",
    200: "#e2e8f0",
    300: "#cbd5e1",
    400: "#94a3b8",
    500: "#64748b",
    600: "#475569",
    700: "#334155",
    800: "#1e293b",
    900: "#0f172a",
    950: "#020617",
}
SHADES = (50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950)

#: Chroma per shade, in OKLCh. Slate is about 1.5x less chromatic than this at
#: the light end; the extra is what makes a theme read as "green" rather than
#: "grey" without turning the panels into paint.
CHROMA = {
    50: 0.006,
    100: 0.012,
    200: 0.020,
    300: 0.028,
    400: 0.034,
    500: 0.038,
    600: 0.038,
    700: 0.034,
    800: 0.030,
    900: 0.028,
    950: 0.032,
}

#: Lightness and chroma of ``card`` — the near-white panel in light mode.
CARD = (0.987, 0.008)

#: Accents below this chroma are treated as neutral (the gray theme).
NEUTRAL = 0.03

#: How far a step may drift from slate's luminance before we call it a bug.
TOLERANCE = 0.015


# --- sRGB <-> OKLab -------------------------------------------------------- #
def _to_linear(value: float) -> float:
    return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4


def _to_srgb(value: float) -> float:
    return 12.92 * value if value <= 0.0031308 else 1.055 * value ** (1 / 2.4) - 0.055


def hex_to_oklab(hex_color: str) -> tuple[float, float, float]:
    red, green, blue = (
        _to_linear(int(hex_color[index : index + 2], 16) / 255) for index in (1, 3, 5)
    )
    l_ = 0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue
    m_ = 0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue
    s_ = 0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue
    l, m, s = (math.copysign(abs(value) ** (1 / 3), value) for value in (l_, m_, s_))
    return (
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    )


def oklab_to_hex(lightness: float, a: float, b: float) -> str:
    l_ = lightness + 0.3963377774 * a + 0.2158037573 * b
    m_ = lightness - 0.1055613458 * a - 0.0638541728 * b
    s_ = lightness - 0.0894841775 * a - 1.2914855480 * b
    l, m, s = (value**3 for value in (l_, m_, s_))
    red = +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    green = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    blue = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    channels = [
        _to_srgb(min(1.0, max(0.0, value))) for value in (red, green, blue)
    ]
    return "#" + "".join(f"{round(channel * 255):02x}" for channel in channels)


def hued(lightness: float, chroma: float, hue: float) -> str:
    """``lightness`` at ``hue`` with as much of ``chroma`` as sRGB can hold."""
    while chroma > 0:
        hex_color = oklab_to_hex(
            lightness, chroma * math.cos(hue), chroma * math.sin(hue)
        )
        back = hex_to_oklab(hex_color)
        if math.hypot(back[1], back[2]) > chroma * 0.9:
            return hex_color
        chroma -= 0.002
    return oklab_to_hex(lightness, 0.0, 0.0)


def polar(hex_color: str) -> tuple[float, float]:
    """The ``(chroma, hue)`` of a colour in OKLCh."""
    _, a, b = hex_to_oklab(hex_color)
    return math.hypot(a, b), math.atan2(b, a)


def luminance(hex_color: str) -> float:
    """Relative luminance, the quantity contrast ratios are made of."""
    red, green, blue = (
        _to_linear(int(hex_color[index : index + 2], 16) / 255) for index in (1, 3, 5)
    )
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


def ramp_for(accent: str) -> dict[str, str]:
    """The surface ramp for one accent: slate's lighting, the accent's hue."""
    accent_chroma, accent_hue = polar(accent)
    neutral = accent_chroma < NEUTRAL
    ramp = {}
    for shade in SHADES:
        lightness = hex_to_oklab(SLATE[shade])[0]
        ramp[str(shade)] = (
            oklab_to_hex(lightness, 0.0, 0.0)
            if neutral
            else hued(lightness, CHROMA[shade], accent_hue)
        )
    ramp["card"] = (
        oklab_to_hex(CARD[0], 0.0, 0.0)
        if neutral
        else hued(CARD[0], CARD[1], accent_hue)
    )
    return ramp


def check_ramp(slug: str, ramp: dict[str, str]) -> None:
    """Refuse to write a ramp that would change a contrast ratio."""
    for shade in SHADES:
        drift = abs(luminance(ramp[str(shade)]) - luminance(SLATE[shade]))
        if drift > TOLERANCE:
            raise SystemExit(
                f"{slug}: surface {shade} drifts {drift:.3f} from slate's "
                "luminance — text contrast would change"
            )


def format_lines(mapping: dict[str, str], per_line: int = 5) -> str:
    items = list(mapping.items())
    rows = [
        "        " + ", ".join(f'"{key}": "{value}"' for key, value in items[start : start + per_line])
        for start in range(0, len(items), per_line)
    ]
    return ",\n".join(rows)


def render(data: dict) -> str:
    themes = data["themes"]
    lines = ["{", f'  "default": "{data["default"]}",', '  "themes": [']
    for index, theme in enumerate(themes):
        lines += [
            "    {",
            f'      "slug": "{theme["slug"]}",',
            f'      "label": "{theme["label"]}",',
            f'      "ink": "{theme["ink"]}",',
            '      "scale": {',
            format_lines(theme["scale"]),
            "      },",
            '      "surface": {',
            format_lines(theme["surface"]),
            "      }",
            "    }" + ("," if index < len(themes) - 1 else ""),
        ]
    lines += ["  ]", "}"]
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    dry_run = "--dry-run" in argv
    data = json.loads(THEMES_FILE.read_text(encoding="utf-8"))

    for theme in data["themes"]:
        theme["surface"] = ramp_for(theme["scale"]["500"])
        check_ramp(theme["slug"], theme["surface"])
        surface = theme["surface"]
        print(
            f"{theme['slug']:7}  100={surface['100']}  500={surface['500']}  "
            f"900={surface['900']}  950={surface['950']}  card={surface['card']}"
        )

    text = render(data)
    json.loads(text)  # never write something we cannot read back
    if dry_run:
        print("\n--dry-run: app/themes.json unchanged")
        return 0

    THEMES_FILE.write_text(text, encoding="utf-8")
    print(f"\nwrote {THEMES_FILE.relative_to(THEMES_FILE.parent.parent)}")
    print("now mirror the new values in mobile/lib/src/theme.dart")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
