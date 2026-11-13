#!/usr/bin/env python3
"""Renders the app icon's sizes from the SVG layers in this folder.

The layers (background, distance, frame) are the one source. They are full bleed
and unmasked, ready for Icon Composer. This script composes them in the
macOS 11-15 shape: a rounded square of 824 by 824 on a 1024 canvas, with the
standard drop shadow, and writes every size the asset catalog needs. It also
copies the layers into App/Resources/AppIcon.icon, the Icon Composer file
macOS 26 uses; its icon.json sets the glass and the dark and tinted variants.

Needs the librsvg and cairo libraries, and Pillow:
    python3 Design/AppIcon/render.py
"""

import ctypes
import ctypes.util
import json
import pathlib
import tempfile

from PIL import Image, ImageDraw, ImageFilter

HERE = pathlib.Path(__file__).resolve().parent
OUTPUT = HERE.parent.parent / "App" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
# The Icon Composer file for macOS 26 and later, built from the same layers.
ICON_ASSETS = HERE.parent.parent / "App" / "Resources" / "AppIcon.icon" / "Assets"
LAYERS = ["background.svg", "distance.svg", "frame.svg"]

# Apple's macOS icon template, in points on a 1024 canvas.
CANVAS = 1024
BODY = 824
RADIUS = 185
SHADOW_OFFSET = 10
SHADOW_BLUR = 14
SHADOW_ALPHA = 0.3

SIZES = [16, 32, 128, 256, 512]


class _Viewport(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double),
                ("width", ctypes.c_double), ("height", ctypes.c_double)]


def _library(name: str) -> ctypes.CDLL:
    path = ctypes.util.find_library(name)
    if not path:
        raise SystemExit(f"lib{name} not found; install librsvg and cairo")
    return ctypes.CDLL(path)


_rsvg = _library("rsvg-2")
_cairo = _library("cairo")
_rsvg.rsvg_handle_new_from_file.restype = ctypes.c_void_p
_rsvg.rsvg_handle_new_from_file.argtypes = [ctypes.c_char_p, ctypes.c_void_p]
_rsvg.rsvg_handle_render_document.argtypes = [
    ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(_Viewport), ctypes.c_void_p
]
_cairo.cairo_image_surface_create.restype = ctypes.c_void_p
_cairo.cairo_create.restype = ctypes.c_void_p
_cairo.cairo_create.argtypes = [ctypes.c_void_p]
_cairo.cairo_surface_write_to_png.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_cairo.cairo_destroy.argtypes = [ctypes.c_void_p]
_cairo.cairo_surface_destroy.argtypes = [ctypes.c_void_p]
_FORMAT_ARGB32 = 0


def render_layer(name: str, size: int) -> Image.Image:
    """One SVG layer as an image of size × size pixels."""
    handle = _rsvg.rsvg_handle_new_from_file(str(HERE / name).encode(), None)
    if not handle:
        raise SystemExit(f"cannot read {name}")
    surface = _cairo.cairo_image_surface_create(_FORMAT_ARGB32, size, size)
    context = _cairo.cairo_create(surface)
    viewport = _Viewport(0, 0, size, size)
    if not _rsvg.rsvg_handle_render_document(handle, context, ctypes.byref(viewport), None):
        raise SystemExit(f"cannot render {name}")
    with tempfile.NamedTemporaryFile(suffix=".png") as file:
        _cairo.cairo_surface_write_to_png(surface, file.name.encode())
        image = Image.open(file.name).convert("RGBA")
    _cairo.cairo_destroy(context)
    _cairo.cairo_surface_destroy(surface)
    return image


def icon(pixels: int) -> Image.Image:
    """The composed icon at a size in pixels, drawn at 4× and scaled down."""
    scale = 4
    big = pixels * scale
    unit = big / CANVAS
    body = round(BODY * unit)
    offset = round((CANVAS - BODY) / 2 * unit)

    artwork = Image.new("RGBA", (body, body))
    for layer in LAYERS:
        artwork.alpha_composite(render_layer(layer, body))

    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, body - 1, body - 1], radius=round(RADIUS * unit), fill=255)

    canvas = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    shadow_mask = Image.new("L", (big, big), 0)
    shadow_mask.paste(mask, (offset, offset + round(SHADOW_OFFSET * unit)))
    shadow.putalpha(shadow_mask.point(lambda value: int(value * SHADOW_ALPHA)))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(SHADOW_BLUR * unit)))

    shaped = Image.new("RGBA", (body, body), (0, 0, 0, 0))
    shaped.paste(artwork, (0, 0), mask)
    canvas.alpha_composite(shaped, (offset, offset))
    return canvas.resize((pixels, pixels), Image.LANCZOS)


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    images = []
    for points in SIZES:
        for factor in (1, 2):
            suffix = "" if factor == 1 else "@2x"
            name = f"icon_{points}x{points}{suffix}.png"
            icon(points * factor).save(OUTPUT / name, optimize=True)
            images.append({"filename": name, "idiom": "mac", "scale": f"{factor}x", "size": f"{points}x{points}"})
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (OUTPUT / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    catalog = OUTPUT.parent / "Contents.json"
    catalog.write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    print(f"Wrote {len(images)} images to {OUTPUT}")
    ICON_ASSETS.mkdir(parents=True, exist_ok=True)
    for layer in LAYERS:
        (ICON_ASSETS / layer).write_bytes((HERE / layer).read_bytes())
    print(f"Copied {len(LAYERS)} layers to {ICON_ASSETS}")


if __name__ == "__main__":
    main()
