# Windows companion interface

Mode: Operate. Preserve yaprflow's quiet utility character and bottom-center recording pill.
Backbone: native Windows desktop controls; utilitarian layout. Deliberately choose Segoe UI for Windows familiarity, OS text scaling and accessibility (an exception to the generic web-font rule).

Settings: one flat form, setup first, then shortcut, behavior and privacy. Immediate boolean changes; shortcut edits apply together because registration can fail. Inline actionable status, no nested dialogs.
History: up to 200 local entries; newest first; live search; list plus read-only, selectable transcript detail; explicit Copy/Delete/Clear actions. Transcripts never auto-copy on failed insertion.
Vocabulary: up to 500 rules; two visible fields, heard phrase and preferred spelling; select to edit inline; add/update/delete. Longest phrase wins, non-cascading replacements.
Nesting budget: one window plus native file dialogs or destructive confirmation. No nested modals.
States: first-run model download, progress/cancel, offline retry, ready, preparing, listening, transcribing, canceled, no speech, insertion withheld, and storage error.

Use OS colors and Microsoft's WPF Fluent control templates for settings, including high contrast. Spacing 8/16/24 DIP, minimum control height 32 DIP. Body 14 DIP, title 26 DIP; regular and semibold only. No decorative gradients or shadows. Overlay: charcoal #182322, light mint #E5F5EF, accent #94D9BC; pill radius 22. No looping decorative motion. Microphone meter reflects actual audio level.

Keyboard: native tab order, labels target inputs, visible focus, Escape cancels recording, buttons named for UI Automation. Overlay is nonactivating to preserve the dictation target. Settings window close hides to tray; Quit is explicit. Actual Windows rendering and accessibility must be tested on Windows; Mac compilation is not a UI check.
