"""sRGB <-> CIE xy conversion following Signify's published conversion guidance
(Wide RGB D65 matrix). Gamut clamping is left to the bridge."""

import math
import re

_HEX = re.compile(r"^#?([0-9a-fA-F]{6})$")


def parse_hex(value):
    match = _HEX.match(str(value).strip())
    if not match:
        raise ValueError("color must be written as RRGGBB")
    digits = match.group(1)
    return tuple(int(digits[i:i + 2], 16) for i in (0, 2, 4))


def _to_linear(value):
    return ((value + 0.055) / 1.055) ** 2.4 if value > 0.04045 else value / 12.92


def _to_gamma(value):
    return 12.92 * value if value <= 0.0031308 else 1.055 * value ** (1 / 2.4) - 0.055


def rgb_to_xy(rgb):
    r, g, b = (_to_linear(c / 255) for c in rgb)
    x = r * 0.664511 + g * 0.154324 + b * 0.162028
    y = r * 0.283881 + g * 0.668433 + b * 0.047685
    z = r * 0.000088 + g * 0.072310 + b * 0.986039
    total = x + y + z
    if total <= 1e-12:
        # Black has no chromaticity; use the D65 white point.
        return 0.3127, 0.3290
    return round(x / total, 4), round(y / total, 4)


def xy_to_hex(x, y):
    """Full-brightness display color for an xy value, as #rrggbb."""
    if y <= 1e-12:
        return "#ffffff"
    big_x = x / y
    big_z = (1 - x - y) / y
    r = big_x * 1.656492 - 0.354851 - big_z * 0.255038
    g = -big_x * 0.707196 + 1.655397 + big_z * 0.036152
    b = big_x * 0.051713 - 0.121364 + big_z * 1.011530
    linear = [max(0.0, c) for c in (r, g, b)]
    peak = max(linear)
    if peak > 1:
        linear = [c / peak for c in linear]
    r, g, b = (round(min(1.0, max(0.0, _to_gamma(c))) * 255) for c in linear)
    return f"#{r:02x}{g:02x}{b:02x}"


def mirek_to_hex(mirek):
    """Approximate display color for a color temperature in mirek."""
    # Tanner Helland's blackbody approximation, in Kelvin / 100.
    kelvin = 1_000_000 / max(1, mirek) / 100
    r = 255.0 if kelvin <= 66 else 329.698727446 * (kelvin - 60) ** -0.1332047592
    if kelvin <= 66:
        g = 99.4708025861 * math.log(kelvin) - 161.1195681661
    else:
        g = 288.1221695283 * (kelvin - 60) ** -0.0755148492
    if kelvin >= 66:
        b = 255.0
    elif kelvin <= 19:
        b = 0.0
    else:
        b = 138.5177312231 * math.log(kelvin - 10) - 305.0447927307
    r, g, b = (round(min(255.0, max(0.0, c))) for c in (r, g, b))
    return f"#{r:02x}{g:02x}{b:02x}"
