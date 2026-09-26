//! sRGB ⇄ CIE xy conversion following Signify's published conversion guidance
//! (Wide RGB D65 matrix). Gamut clamping is left to the bridge.

use anyhow::{Result, bail};

pub fn parse_hex(hex: &str) -> Result<[u8; 3]> {
    let hex = hex.trim().trim_start_matches('#');
    if hex.len() != 6 || !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("color must be written as RRGGBB");
    }
    let channel = |index: usize| u8::from_str_radix(&hex[index..index + 2], 16);
    Ok([channel(0)?, channel(2)?, channel(4)?])
}

fn to_linear(value: f64) -> f64 {
    if value > 0.04045 {
        ((value + 0.055) / 1.055).powf(2.4)
    } else {
        value / 12.92
    }
}

fn to_gamma(value: f64) -> f64 {
    if value <= 0.003_130_8 {
        12.92 * value
    } else {
        1.055 * value.powf(1.0 / 2.4) - 0.055
    }
}

pub fn rgb_to_xy(rgb: [u8; 3]) -> (f64, f64) {
    let [r, g, b] = rgb.map(|channel| to_linear(f64::from(channel) / 255.0));
    let x = r * 0.664_511 + g * 0.154_324 + b * 0.162_028;
    let y = r * 0.283_881 + g * 0.668_433 + b * 0.047_685;
    let z = r * 0.000_088 + g * 0.072_310 + b * 0.986_039;
    let sum = x + y + z;
    if sum <= f64::EPSILON {
        // Black has no chromaticity; use the D65 white point.
        return (0.3127, 0.3290);
    }
    (round4(x / sum), round4(y / sum))
}

/// Full-brightness display color for an xy value, as `#rrggbb`.
pub fn xy_to_hex(x: f64, y: f64) -> String {
    if y <= f64::EPSILON {
        return "#ffffff".to_owned();
    }
    let luminance = 1.0;
    let big_x = luminance / y * x;
    let big_z = luminance / y * (1.0 - x - y);
    let r = big_x * 1.656_492 - luminance * 0.354_851 - big_z * 0.255_038;
    let g = -big_x * 0.707_196 + luminance * 1.655_397 + big_z * 0.036_152;
    let b = big_x * 0.051_713 - luminance * 0.121_364 + big_z * 1.011_530;
    let linear = [r, g, b].map(|channel| channel.max(0.0));
    let peak = linear.iter().copied().fold(0.0_f64, f64::max);
    let scaled = if peak > 1.0 {
        linear.map(|channel| channel / peak)
    } else {
        linear
    };
    let [r, g, b] = scaled.map(|channel| (to_gamma(channel).clamp(0.0, 1.0) * 255.0).round() as u8);
    format!("#{r:02x}{g:02x}{b:02x}")
}

/// Approximate display color for a color temperature in mirek.
pub fn mirek_to_hex(mirek: u32) -> String {
    // Tanner Helland's blackbody approximation, in Kelvin / 100.
    let kelvin = 1_000_000.0 / f64::from(mirek.max(1)) / 100.0;
    let r = if kelvin <= 66.0 {
        255.0
    } else {
        329.698_727_446 * (kelvin - 60.0).powf(-0.133_204_759_2)
    };
    let g = if kelvin <= 66.0 {
        99.470_802_586_1 * kelvin.ln() - 161.119_568_166_1
    } else {
        288.122_169_528_3 * (kelvin - 60.0).powf(-0.075_514_849_2)
    };
    let b = if kelvin >= 66.0 {
        255.0
    } else if kelvin <= 19.0 {
        0.0
    } else {
        138.517_731_223_1 * (kelvin - 10.0).ln() - 305.044_792_730_7
    };
    let [r, g, b] = [r, g, b].map(|channel| channel.clamp(0.0, 255.0).round() as u8);
    format!("#{r:02x}{g:02x}{b:02x}")
}

fn round4(value: f64) -> f64 {
    (value * 10_000.0).round() / 10_000.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_parsing_accepts_hash_and_rejects_garbage() {
        assert_eq!(parse_hex("#ff8000").ok(), Some([255, 128, 0]));
        assert_eq!(parse_hex("00FF00").ok(), Some([0, 255, 0]));
        assert!(parse_hex("fff").is_err());
        assert!(parse_hex("gg0000").is_err());
    }

    #[test]
    fn primaries_land_near_their_wide_gamut_corners() {
        let (x, y) = rgb_to_xy([255, 0, 0]);
        assert!(x > 0.65 && y < 0.35, "red at {x},{y}");
        let (x, y) = rgb_to_xy([0, 0, 255]);
        assert!(x < 0.2 && y < 0.1, "blue at {x},{y}");
    }

    #[test]
    fn xy_round_trip_preserves_hue() {
        for rgb in [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 128, 0]] {
            let (x, y) = rgb_to_xy(rgb);
            let back = parse_hex(&xy_to_hex(x, y)).expect("valid hex");
            let dominant = |c: [u8; 3]| (0..3).max_by_key(|&i| c[i]).unwrap_or(0);
            assert_eq!(dominant(back), dominant(rgb), "{rgb:?} -> {back:?}");
        }
    }

    #[test]
    fn warm_temperatures_are_orange_and_cool_ones_blueish() {
        let warm = parse_hex(&mirek_to_hex(454)).expect("valid hex");
        let cool = parse_hex(&mirek_to_hex(153)).expect("valid hex");
        assert!(warm[0] > warm[2]);
        assert!(cool[2] > warm[2]);
    }
}
