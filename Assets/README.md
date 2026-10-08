# Artwork

The application and menu-bar icons share the original six-ray "Shift" mark in
`Sources/Claudeway/BrandIcon.swift`. The final artwork is native vector code,
rendered into a 1024×1024 PNG by `RenderAppIcon.swift`; build.sh creates the ICNS.
Concept exploration used image generation, but generated draft bitmaps are not
part of this repository. Source artwork and final icon are included under MIT.
The mark is not the official Claude logo. Claude is a trademark of Anthropic.

Recreate the PNG on macOS from the repository root:

```sh
mkdir -p .build/artwork
swiftc -parse-as-library Sources/Claudeway/BrandIcon.swift Assets/RenderAppIcon.swift -o .build/artwork/render-icon
.build/artwork/render-icon Assets/AppIcon.png
```

The PNG's EXIF contains pixel dimensions only, not author, location or timestamps.
