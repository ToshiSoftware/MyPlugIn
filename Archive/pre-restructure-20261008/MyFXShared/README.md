# MyFXShared

Parts shared by MyDAW's built-in effects (MyReverb, MyDelay):

- `MyFXMeterPeaks.swift` – input/output peak store written on the render thread.
- `MyFXRendering.swift` – `MyFXRenderer`: input buffers and the render block
  (pull input, in-place rendering, sample-accurate parameter events).
- `MyFXEditor.swift` – the 300 x 400 editor frame in MyDAW's mixer look: IN/OUT
  meters, silver faders, typed values, mode menu, view controller.

The effects import this module only `#if canImport(MyFXShared)`, because MyDAW
compiles all of them into one module (`MyDAW/scripts/sync-builtin-plugins.sh`).
Type names start with "MyFX" to stay clear of MyDAW's own.
