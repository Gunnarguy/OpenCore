# OpenCore app artwork

[source, 2026-10-31] Coordinated app icons were generated with the built-in image tool, then resized
into each platform's asset catalog. The iPhone master is an opaque 1024 px image. The Mac asset has
transparency outside its rounded tile. These are artwork, not measurement or evidence marks.

## Final prompt set

[design] iPhone master: a production OpenCore icon for a personal knowledge and evidence app, full
bleed opaque square, navy background, two sculpted translucent open arcs forming an O around a
luminous pearl and three evidence nodes. Cyan #85EBF5, mint #85F0C7 and lavender #CCB8FF glass,
restrained highlights, broad shapes legible at 32 px. No text, literal brain, lock, device frame,
watermark or premade corner mask; the OS applies the iPhone mask.

[design] Mac variation: preserve that exact central mark and colors inside a rounded square tile
occupying about 84 percent of the canvas, with a restrained bevel and shadow, transparent outside.
No text, badges, device or watermark.

[source] Assets: `OpenCoreMac/Resources/Assets.xcassets/AppIcon.appiconset` and
`OpenCorePhone/Resources/Assets.xcassets/AppIcon.appiconset`. `BrandMark.imageset` reuses the opaque
phone master for the pairing/home screen.
