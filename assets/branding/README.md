# Corenyth logos

- `corenyth-logo-primary.png`: approved gradient background with dark happy ghost; Android launcher source.
- `corenyth-logo-dark.png`: white ghost with transparent background; branding on the app's dark surfaces.
- `corenyth-logo-light.png`: black ghost with transparent background; branding on light surfaces.

The animated conversation companion remains rendered by `lib/ui/ghost_mascot.dart`.
Regenerate Android launcher resources after replacing the primary image:

```sh
dart run flutter_launcher_icons
```

The white source currently contains generation artifacts around its eyes and edges; replace this file with a cleaned version when available.
