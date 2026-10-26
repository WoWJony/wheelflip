# WheelFlip icon

The ladybird's oval shell resembles a computer mouse, with a scroll wheel in the center. The artwork uses a warm white background, muted red shell, and graphite details.

- `wheelflip-icon-v2.svg` is the editable source for the current icon.
- `render-icon.swift` renders the asset catalog using AppKit and packages an ICNS file with the system `iconutil`.
- `../WheelFlip/Resources/Assets.xcassets/AppIconV2.appiconset/` contains the generated app assets.
- Extra previews are written to the ignored `output/wheelflip-icon/` directory.

Run `swift app/IconSource/render-icon.swift` from the repository root. The rendering script uses no third-party libraries.

Generative image exploration informed the visual direction; the shipped artwork is rendered from the editable SVG. The project artwork is included under the repository's MIT license.
