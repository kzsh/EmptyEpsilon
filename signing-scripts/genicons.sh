#!/bin/bash

set -e

# Resolve the script's source path, handling symbolic links
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done

SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

OUTPUT_DIR="${SCRIPT_DIR}/Sources/${APP_NAME}/Assets.xcassets/AppIcon.appiconset"
SOURCE_IMAGE="${1:-}"

usage() {
    echo "Usage: $0 [SOURCE_IMAGE]"
    echo ""
    echo "Generate all required app icon sizes for App Store / TestFlight."
    echo "If SOURCE_IMAGE is not provided, a solid-color placeholder is generated."
    echo ""
    echo "Arguments:"
    echo "  SOURCE_IMAGE    Path to a square source image (1024x1024 recommended)"
    echo ""
    echo "Output: Sources/${APP_NAME}/Assets.xcassets/AppIcon.appiconset/"
    echo ""
    echo "After running, ensure Package.swift includes:"
    echo "  resources: [.process(\"Assets.xcassets\")]"
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi

# Generate a solid-color placeholder if no source image provided
if [[ -z "$SOURCE_IMAGE" ]]; then
    echo "No source image provided — generating placeholder..."
    SOURCE_IMAGE=$(mktemp /tmp/AppIconSource.XXXXXX.png)
    trap 'rm -f "$SOURCE_IMAGE"' EXIT
    python3 - "$SOURCE_IMAGE" <<'EOF'
import sys, struct, zlib

def make_png(size, r, g, b):
    raw = b''.join(b'\x00' + bytes([r, g, b] * size) for _ in range(size))
    def chunk(tag, data):
        payload = tag + data
        return struct.pack('>I', len(data)) + payload + struct.pack('>I', zlib.crc32(payload) & 0xffffffff)
    ihdr = struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', zlib.compress(raw))
            + chunk(b'IEND', b''))

with open(sys.argv[1], 'wb') as f:
    f.write(make_png(1024, 74, 144, 226))  # cornflower blue placeholder
EOF
elif [[ ! -f "$SOURCE_IMAGE" ]]; then
    echo "Error: Source image not found: $SOURCE_IMAGE"
    exit 1
else
    # Resize source to 1024x1024 if not already square at that size
    W=$(sips -g pixelWidth "$SOURCE_IMAGE" | awk '/pixelWidth/{print $2}')
    H=$(sips -g pixelHeight "$SOURCE_IMAGE" | awk '/pixelHeight/{print $2}')
    if [[ "$W" != "1024" || "$H" != "1024" ]]; then
        echo "Resizing source from ${W}x${H} to 1024x1024..."
        RESIZED=$(mktemp /tmp/AppIconSource.XXXXXX.png)
        trap 'rm -f "$RESIZED"' EXIT
        sips -s format png -z 1024 1024 "$SOURCE_IMAGE" --out "$RESIZED" > /dev/null
        SOURCE_IMAGE="$RESIZED"
    fi
fi

mkdir -p "$OUTPUT_DIR"

# Generate one PNG per unique pixel size, reused across multiple icon slots
echo "Generating icon sizes..."
for size in 20 29 40 58 60 76 80 87 120 152 167 180 1024; do
    out="${OUTPUT_DIR}/${size}.png"
    echo "  ${size}x${size}"
    sips -z "$size" "$size" "$SOURCE_IMAGE" --out "$out" > /dev/null
done

# Write Contents.json — multiple slots can share the same file where pixel sizes match
cat > "${OUTPUT_DIR}/Contents.json" <<'CONTENTS'
{
  "images": [
    { "idiom": "iphone",        "scale": "2x", "size": "20x20",     "filename": "40.png"   },
    { "idiom": "iphone",        "scale": "3x", "size": "20x20",     "filename": "60.png"   },
    { "idiom": "iphone",        "scale": "2x", "size": "29x29",     "filename": "58.png"   },
    { "idiom": "iphone",        "scale": "3x", "size": "29x29",     "filename": "87.png"   },
    { "idiom": "iphone",        "scale": "2x", "size": "40x40",     "filename": "80.png"   },
    { "idiom": "iphone",        "scale": "3x", "size": "40x40",     "filename": "120.png"  },
    { "idiom": "iphone",        "scale": "2x", "size": "60x60",     "filename": "120.png"  },
    { "idiom": "iphone",        "scale": "3x", "size": "60x60",     "filename": "180.png"  },
    { "idiom": "ipad",          "scale": "1x", "size": "20x20",     "filename": "20.png"   },
    { "idiom": "ipad",          "scale": "2x", "size": "20x20",     "filename": "40.png"   },
    { "idiom": "ipad",          "scale": "1x", "size": "29x29",     "filename": "29.png"   },
    { "idiom": "ipad",          "scale": "2x", "size": "29x29",     "filename": "58.png"   },
    { "idiom": "ipad",          "scale": "1x", "size": "40x40",     "filename": "40.png"   },
    { "idiom": "ipad",          "scale": "2x", "size": "40x40",     "filename": "80.png"   },
    { "idiom": "ipad",          "scale": "1x", "size": "76x76",     "filename": "76.png"   },
    { "idiom": "ipad",          "scale": "2x", "size": "76x76",     "filename": "152.png"  },
    { "idiom": "ipad",          "scale": "2x", "size": "83.5x83.5", "filename": "167.png"  },
    { "idiom": "ios-marketing", "scale": "1x", "size": "1024x1024", "filename": "1024.png" }
  ],
  "info": { "author": "xcode", "version": 1 }
}
CONTENTS

echo ""
echo "Icons written to: ${OUTPUT_DIR}"
echo ""
echo "Make sure Package.swift declares the asset catalog as a resource:"
echo "  .target("
echo "    name: \"${APP_NAME}\","
echo "    resources: [.process(\"Assets.xcassets\")]"
echo "  )"
