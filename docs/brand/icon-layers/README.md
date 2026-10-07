# Icon layers (for Icon Composer / Liquid Glass)

macOS 26 app icons can be layered so the system adds Liquid Glass depth,
highlights and tinted/dark variants. Open Icon Composer (Xcode › Open
Developer Tool), create a new icon, and add these as layers, back to front:

1. `1-background.svg`: fill the whole canvas (the system applies the squircle mask).
2. `2-stage.svg`: the gradient stage with sparkles. Enable glass / specular.
3. `3-camera-inset.svg`: the camera inset with the record lens. Enable glass; keep it the top layer.

Save as `AppIcon.icon` into `App/Resources/` and set
`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` (already set). The flat
`AppIcon.appiconset` stays as the fallback for macOS 15.
