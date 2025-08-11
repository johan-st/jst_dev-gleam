# TODO


## State management

- Implemented: Ephemeral UI state reset on route change.
  - Reset on navigation: `profile_menu_open`, `notice`, `delete_confirmation`, `copy_feedback`, `expanded_urls`, `login_form_open`, `login_username`, `login_password`, `login_loading`.
  - Persistent across pages: `articles`, `short_urls`, `session`, `keyboard`, `base_uri`, notifications form (intentionally kept for convenience).

Remaining:
- Revisit which view-specific fields should be kept inside page-specific view modules rather than app `Model`.


## Types

- Make sure the Page type contains everything needed to render the main content of the page.

## View

- Implemented: Moved page-specific rendering out of `jst_lustre.gleam` into modules under `pages/` and `view/`.
- Next: Ensure `Page` contains all data needed for main content; avoid passing full `Model` into page views (use callbacks/fields instead).

## Functions

- Resduce the scope of passed variables to the minimum. Do not pass the whole model for instance.
