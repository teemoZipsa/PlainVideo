from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
ASSET_ROOT = ROOT / "assets" / "store-listing"
SOURCE_DIR = ASSET_ROOT / "source" / "shared"
OUTPUT_DIR = ASSET_ROOT / "upload"
ICON_PATH = ROOT / "packaging" / "icons" / "plainvideo-icon-master.png"

FONT_BOLD = Path(r"C:\Windows\Fonts\segoeuib.ttf")

WHITE = "#F6F8FB"
ACCENT = "#54C8FF"
GLOW = (0, 142, 255)


def open_rgb(path: Path) -> Image.Image:
    with Image.open(path) as image:
        return image.convert("RGB")


def open_rgba(path: Path) -> Image.Image:
    with Image.open(path) as image:
        return image.convert("RGBA")


def save_png(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=True, compress_level=9)


def cover(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    target_width, target_height = size
    source_ratio = image.width / image.height
    target_ratio = target_width / target_height

    if source_ratio > target_ratio:
        crop_width = round(image.height * target_ratio)
        left = (image.width - crop_width) // 2
        image = image.crop((left, 0, left + crop_width, image.height))
    elif source_ratio < target_ratio:
        crop_height = round(image.width / target_ratio)
        top = (image.height - crop_height) // 2
        image = image.crop((0, top, image.width, top + crop_height))

    return image.resize(size, Image.Resampling.LANCZOS)


def centered_text(
    draw: ImageDraw.ImageDraw,
    y: int,
    text: str,
    font: ImageFont.FreeTypeFont,
    fill: str,
    canvas_width: int,
) -> None:
    left, top, right, _ = draw.textbbox((0, 0), text, font=font)
    x = (canvas_width - (right - left)) // 2
    draw.text(
        (x, y - top),
        text,
        font=font,
        fill=fill,
        stroke_width=max(2, canvas_width // 480),
        stroke_fill="#07101E",
    )


def add_title(image: Image.Image, y: int, size: int, line_y: int) -> None:
    draw = ImageDraw.Draw(image)
    font = ImageFont.truetype(str(FONT_BOLD), size)
    centered_text(draw, y, "PlainVideo", font, WHITE, image.width)
    line_width = round(image.width * 0.13)
    line_height = max(8, round(image.width * 0.006))
    left = (image.width - line_width) // 2
    draw.rounded_rectangle(
        (left, line_y, left + line_width, line_y + line_height),
        radius=line_height // 2,
        fill=ACCENT,
    )


def add_icon(image: Image.Image, edge: int, top: int) -> Image.Image:
    icon = open_rgba(ICON_PATH)
    icon.thumbnail((edge, edge), Image.Resampling.LANCZOS)
    x = (image.width - icon.width) // 2

    canvas = image.convert("RGBA")
    alpha = icon.getchannel("A")
    blur_radius = max(10, edge // 24)
    glow_alpha = alpha.filter(ImageFilter.GaussianBlur(blur_radius)).point(
        lambda value: round(value * 0.32)
    )
    glow = Image.new("RGBA", icon.size, (*GLOW, 0))
    glow.putalpha(glow_alpha)

    canvas.alpha_composite(glow, (x, top))
    canvas.alpha_composite(icon, (x, top))
    return canvas.convert("RGB")


def build_poster() -> Image.Image:
    background = cover(
        open_rgb(SOURCE_DIR / "poster-background-master.png"),
        (1440, 2160),
    )
    image = add_icon(background, edge=900, top=455)
    add_title(image, y=132, size=150, line_y=342)
    return image


def build_box_art() -> Image.Image:
    background = cover(
        open_rgb(SOURCE_DIR / "box-art-background-master.png"),
        (2160, 2160),
    )
    image = add_icon(background, edge=1030, top=385)
    add_title(image, y=118, size=174, line_y=345)
    return image


def build_app_tile_master() -> Image.Image:
    background = cover(
        open_rgb(SOURCE_DIR / "box-art-background-master.png"),
        (1200, 1200),
    )
    return add_icon(background, edge=930, top=132)


def validate_outputs(expected: dict[Path, tuple[int, int]]) -> None:
    for path, size in expected.items():
        with Image.open(path) as image:
            if image.size != size:
                raise RuntimeError(f"{path} has {image.size}; expected {size}")
            if image.mode != "RGB":
                raise RuntimeError(f"{path} has mode {image.mode}; expected RGB")
        if path.stat().st_size > 50 * 1024 * 1024:
            raise RuntimeError(f"{path} exceeds the 50 MB Store limit")


def main() -> None:
    required = (
        SOURCE_DIR / "poster-background-master.png",
        SOURCE_DIR / "box-art-background-master.png",
        ICON_PATH,
        FONT_BOLD,
    )
    missing = [path for path in required if not path.is_file()]
    if missing:
        raise FileNotFoundError(f"Missing Store asset inputs: {missing}")

    poster = build_poster()
    box_art = build_box_art()
    tile_master = build_app_tile_master()

    source_outputs = {
        SOURCE_DIR / "poster-art-master.png": poster,
        SOURCE_DIR / "box-art-master.png": box_art,
        SOURCE_DIR / "app-tile-master.png": tile_master,
    }
    for path, image in source_outputs.items():
        save_png(image, path)

    upload_outputs: dict[Path, Image.Image] = {}
    for locale in ("en-US", "ko-KR"):
        upload_outputs[OUTPUT_DIR / locale / "poster-1440x2160.png"] = poster
        upload_outputs[OUTPUT_DIR / locale / "box-art-2160x2160.png"] = box_art

    upload_outputs[OUTPUT_DIR / "shared" / "app-tile-300x300.png"] = cover(
        tile_master, (300, 300)
    )
    upload_outputs[OUTPUT_DIR / "shared" / "store-logo-150x150.png"] = cover(
        tile_master, (150, 150)
    )
    upload_outputs[OUTPUT_DIR / "shared" / "store-logo-71x71.png"] = cover(
        tile_master, (71, 71)
    )

    for path, image in upload_outputs.items():
        save_png(image, path)

    expected = {
        SOURCE_DIR / "poster-art-master.png": (1440, 2160),
        SOURCE_DIR / "box-art-master.png": (2160, 2160),
        SOURCE_DIR / "app-tile-master.png": (1200, 1200),
        **{path: image.size for path, image in upload_outputs.items()},
    }
    validate_outputs(expected)

    print(f"Built {len(upload_outputs)} upload files and 3 editable masters")
    for path in upload_outputs:
        print(path.relative_to(ROOT))


if __name__ == "__main__":
    main()
