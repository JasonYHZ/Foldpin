# Settings header visual QA

**Final result: blocked**

Scope: correct the settings header to match the user's Raycast reference; retain Foldpin's existing native app and six real settings categories.

## Source and implementation evidence

- Source: running Raycast Settings, saved as docs/engineering/screenshots/settings-s1/raycast-launcher-top.png and raycast-launcher-scrolled.png.
- Source dimensions: 782 × 768 pixels, native 1 pixel per point.
- Before implementation: running Foldpin Settings at 900 × 680 pixels, also 1 pixel per point; foldpin-header-before-top.png and foldpin-header-before-scrolled.png in the same folder.
- Full window screenshots were opened. Focused top 140 pt comparisons are saved as header-before-comparison.png; both remain at native 1× scale with unused canvas padding. Their different window widths are recorded, not scaled into a false match. Categories differ because Raycast Launcher and Foldpin Appearance provide scrollable forms; comparison is restricted to header behavior/layout.
- Updated implementation screenshot: unavailable pending permission to launch the rebuilt isolated preview. Offscreen screenshots are not accepted as proof of the toolbar's live compositing.

## Findings and comparison history

- [P1] Title visibility: Raycast hides the title at the top and reveals it after scrolling; Foldpin kept it visible. Updated code tracks normalized scroll distance and fades title in/out. Native scroll tests pass, visual acceptance pending.
- [P1] Alignment: Raycast places the title just after the arrows; Foldpin positioned it at the far right. Updated title item is navigational so AppKit places it in the leading group. Native geometry test passes.
- [P1] Toolbar band and content cutoff: Foldpin has a solid horizontal backing and cuts content sharply at the bottom. Updated code hides the toolbar background and extends the scroll view below the header with a soft scroll edge and content inset. Live appearance remains unverified.
- [P2] Typography: Foldpin used 20 pt semibold; Raycast's compact header is approximately 16 pt medium. Updated to 16 pt medium with truncation.

## Required fidelity surfaces

Typography, spacing and colors: covered by the focused comparison above, pending updated capture. Icons: existing SF Symbols/native navigation controls, no new bitmap assets required. Copy: Foldpin keeps its own localized category names and actions; no Raycast account/extension text copied into the app. Sidebar settings content is outside this correction's scope.

## Validation and next step

Debug build and 3 native checks pass, including top/scrolled/top title visibility, title leading position, six categories in both languages/themes/sizes, working history and retained hosts. A current isolated preview is built. Automatic approval review previously required explicit user confirmation to launch this temporary self-signed preview, so it has not been launched again. Next: obtain that confirmation, capture matching before/after states, and validate masking visually. Do not mark passed until the post-fix comparison exists.
