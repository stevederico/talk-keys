# Talku

**Talku** = character · **Talk Keys** = product

Flat **2D vector** packaging kyara (not 3D). Cream speech-bubble body, mint ears, coral blush, speaking mouth.

## Official assets

| File | Use |
|------|-----|
| **`talku.jpg`** | Master art (README portrait) |
| **`talku-banner.jpg`** | Wide README banner |
| **`talku-appicon.jpg`** | Cropped + centered square |

## Generated icons (`scripts/build-icons.sh`)

From `talku.jpg`:

| File | Use |
|------|-----|
| `Resources/AppIcon-1024.png` | Master app icon |
| `Resources/AppIcon.icns` | Finder / Accessibility / Login Items |

Rebuild icons after replacing `talku.jpg` (needs Python 3 + Pillow):

```bash
./scripts/build-icons.sh
```

Committed `talku.jpg`, `talku-banner.jpg`, and `AppIcon.icns` are enough to install. You only run this script if you change the master art.
